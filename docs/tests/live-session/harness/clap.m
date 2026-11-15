// rd-clap: how long a controller's microphone takes to reach Remote Display Microphone
// (spec, Testing plan › Mic latency: under 150 ms on a LAN). Runs on the host while a
// controller forwards its microphone, and records two inputs at once: a reference
// microphone next to the controller's, and Remote Display Microphone. For each clap it
// reports the time between its onset in each, from the host time Core Audio stamps on
// every buffer, plus the input latency the reference device reports: a stamp says when
// the device acquired a sample, which is that much after the sound reached it.
//
//   rd-clap --list                   the inputs, the default first, and how each connects
//   rd-clap [--ref NAME] [--seconds N]
//   rd-clap --self-test              the onset detection and pairing on generated claps;
//                                    no microphone
//
// Without --ref the reference is the first built-in or wired input: a Bluetooth or
// virtual input stamps its samples too late to time anything against.
//
// Needs microphone access, so the Makefile runs it as rd-clap.app.
#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 48000.0
#define MIC_UID "RemoteDisplayMicrophone_UID"
#define WINDOW 48           // 1 ms
#define QUIET_MS 300        // a new clap needs this much quiet before it
#define MAX_DELAY_MS 1000   // a clap further apart than this isn't the same clap
#define LIMIT_MS 150.0

typedef struct {
    float* samples;
    size_t count, capacity;
    double* buffer_ns;      // host time of each buffer's first sample
    size_t* buffer_at;      // where that buffer starts in samples
    size_t buffers, buffer_capacity;
    size_t untimed, unkept; // buffers dropped: without a host time, or past the end
} Track;

static double ns_per_tick;

static void track_init(Track* t, double seconds) {
    t->capacity = (size_t)(seconds * RATE) + 4800;
    t->samples = calloc(t->capacity, sizeof(float));
    t->buffer_capacity = t->capacity / 64;
    t->buffer_ns = calloc(t->buffer_capacity, sizeof(double));
    t->buffer_at = calloc(t->buffer_capacity, sizeof(size_t));
    t->count = t->buffers = t->untimed = t->unkept = 0;
}

// Host time of sample `i`, from the buffer it arrived in.
static double time_of(const Track* t, size_t i) {
    size_t lo = 0, hi = t->buffers;
    while (hi - lo > 1) {
        size_t mid = (lo + hi) / 2;
        if (t->buffer_at[mid] <= i) lo = mid; else hi = mid;
    }
    return t->buffer_ns[lo] + (double)(i - t->buffer_at[lo]) * 1e9 / RATE;
}

static int by_value(const void* a, const void* b) {
    float x = *(const float*)a, y = *(const float*)b;
    return (x > y) - (x < y);
}

// Each clap's onset: the first 1 ms window whose peak is above the threshold after at
// least QUIET_MS without one. The threshold is 10 times the median window peak (the
// room), and at least 0.02.
static size_t onsets(const Track* t, double* out, size_t max, float* loudest) {
    size_t windows = t->count / WINDOW, n = 0;
    *loudest = 0;
    if (!windows || !t->buffers) return 0;
    float* peaks = malloc(windows * sizeof(float));
    for (size_t w = 0; w < windows; w++) {
        float p = 0;
        for (size_t i = w * WINDOW; i < (w + 1) * WINDOW; i++) p = fmaxf(p, fabsf(t->samples[i]));
        peaks[w] = p;
        *loudest = fmaxf(*loudest, p);
    }
    float* sorted = malloc(windows * sizeof(float));
    memcpy(sorted, peaks, windows * sizeof(float));
    qsort(sorted, windows, sizeof(float), by_value);
    float threshold = fmaxf(sorted[windows / 2] * 10, 0.02f);
    free(sorted);
    double last = -1e18;
    for (size_t w = 0; w < windows; w++) {
        if (peaks[w] <= threshold) continue;
        double ns = time_of(t, w * WINDOW);
        if (ns - last > QUIET_MS * 1e6 && n < max) out[n++] = ns;
        last = ns;
    }
    free(peaks);
    return n;
}

// Pairs each reference clap with the Remote Display Microphone clap that follows it
// before the next reference clap, and prints the delays, each with the reference's
// input latency added. A clap only one of them heard stays unpaired, so it can't shift
// the claps after it. Returns how many were paired and their median. `ref_late` is set
// when the microphone heard most claps before the reference did, which only a reference
// with late time stamps explains.
static size_t compare(const Track* ref, const Track* mic, double ref_latency_ms, double* median, bool* ref_late) {
    double r[256], m[256], delays[256];
    float ref_loudest, mic_loudest;
    size_t nr = onsets(ref, r, 256, &ref_loudest), nm = onsets(mic, m, 256, &mic_loudest), n = 0, led = 0;
    printf("Claps heard: %zu by the reference (loudest %.3f), %zu in Remote Display Microphone (loudest %.3f)\n",
           nr, ref_loudest, nm, mic_loudest);
    for (size_t i = 0, j = 0; i < nr; i++) {
        while (j < nm && m[j] < r[i]) j++;
        // The nearest microphone clap, either side: before the reference's means it led.
        double after = j < nm ? m[j] - r[i] : 1e18, before = j > 0 ? r[i] - m[j - 1] : 1e18;
        if (before < after && before < MAX_DELAY_MS * 1e6 / 2) led++;
        double ms = after / 1e6;
        if (j == nm || ms > MAX_DELAY_MS || (i + 1 < nr && m[j] >= r[i + 1])) {
            printf("  clap %zu: not in Remote Display Microphone\n", i + 1);
            continue;
        }
        printf("  clap %zu: %.1f ms\n", i + 1, ms + ref_latency_ms);
        delays[n++] = ms + ref_latency_ms;
        j++;
    }
    for (size_t i = 1; i < n; i++)  // insertion sort; a few dozen at most
        for (size_t k = i; k > 0 && delays[k - 1] > delays[k]; k--) {
            double x = delays[k]; delays[k] = delays[k - 1]; delays[k - 1] = x;
        }
    *median = n ? (n % 2 ? delays[n / 2] : (delays[n / 2 - 1] + delays[n / 2]) / 2) : 0;
    *ref_late = nr > 0 && led * 2 > nr;
    return n;
}

static void on_input(void* user, AudioQueueRef q, AudioQueueBufferRef buf, const AudioTimeStamp* start,
                     UInt32 packets, const AudioStreamPacketDescription* desc) {
    (void)packets; (void)desc;
    Track* t = user;
    size_t n = buf->mAudioDataByteSize / sizeof(float);
    if (!(start->mFlags & kAudioTimeStampHostTimeValid)) {
        t->untimed++;
    } else if (t->count + n > t->capacity || t->buffers >= t->buffer_capacity) {
        t->unkept++;
    } else {
        memcpy(t->samples + t->count, buf->mAudioData, n * sizeof(float));
        t->buffer_ns[t->buffers] = (double)start->mHostTime * ns_per_tick;
        t->buffer_at[t->buffers++] = t->count;
        t->count += n;
    }
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static AudioQueueRef record(Track* t, NSString* uid) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    AudioQueueRef q = NULL;
    CFStringRef cf = (__bridge CFStringRef)uid;
    OSStatus st = AudioQueueNewInput(&f, on_input, t, NULL, kCFRunLoopCommonModes, 0, &q);
    if (!st) st = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, sizeof cf);
    for (int i = 0; !st && i < 8; i++) {
        AudioQueueBufferRef b;
        st = AudioQueueAllocateBuffer(q, 480 * sizeof(float), &b);
        if (!st) st = AudioQueueEnqueueBuffer(q, b, 0, NULL);
    }
    if (!st) st = AudioQueueStart(q, NULL);
    if (st) {
        printf("can't record from %s: OSStatus %d\n", uid.UTF8String, (int)st);
        exit(1);
    }
    return q;
}

static NSString* prop_string(AudioObjectID dev, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &s) || !s) return @"";
    return (__bridge_transfer NSString*)s;
}

static UInt32 prop_u32(AudioObjectID object, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 value = 0, size = sizeof value;
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, &value) ? 0 : value;
}

// The device's first input stream, or kAudioObjectUnknown when it has none.
static AudioStreamID input_stream(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) || size < sizeof(AudioStreamID)) return kAudioObjectUnknown;
    AudioStreamID streams[size / sizeof(AudioStreamID)];
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, streams) ? kAudioObjectUnknown : streams[0];
}

// How long after a sound reaches the device its samples are stamped, as the device
// reports it: its input latency plus its input stream's, in ms.
static double input_latency_ms(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    Float64 rate = 0;
    UInt32 size = sizeof rate;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &rate) || rate <= 0) return 0;
    UInt32 frames = prop_u32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) +
                    prop_u32(input_stream(dev), kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    return frames * 1000.0 / rate;
}

// How the device connects, and whether that's a connection whose time stamps can be
// trusted as a reference: built in or on a cable.
static NSString* transport(AudioObjectID dev, BOOL* wired) {
    UInt32 type = prop_u32(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
    *wired = type == kAudioDeviceTransportTypeBuiltIn || type == kAudioDeviceTransportTypeUSB ||
             type == kAudioDeviceTransportTypeFireWire || type == kAudioDeviceTransportTypeThunderbolt ||
             type == kAudioDeviceTransportTypePCI;
    switch (type) {
        case kAudioDeviceTransportTypeBuiltIn: return @"built in";
        case kAudioDeviceTransportTypeUSB: return @"USB";
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: return @"Bluetooth";
        case kAudioDeviceTransportTypeVirtual: return @"virtual";
        case kAudioDeviceTransportTypeAggregate:
        case kAudioDeviceTransportTypeAutoAggregate: return @"aggregate";
        default: return *wired ? @"wired" : @"other";
    }
}

// Input devices as {name, uid, id}, the default input first.
static NSArray<NSArray*>* inputs(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    AudioObjectID devs[size / sizeof(AudioObjectID) + 1];
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);
    AudioObjectID def = prop_u32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice,
                                 kAudioObjectPropertyScopeGlobal);
    NSMutableArray* out = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        if (input_stream(devs[i]) == kAudioObjectUnknown) continue;
        NSArray* entry = @[ prop_string(devs[i], kAudioObjectPropertyName), prop_string(devs[i], kAudioDevicePropertyDeviceUID), @(devs[i]) ];
        if (devs[i] == def) [out insertObject:entry atIndex:0]; else [out addObject:entry];
    }
    return out;
}

// A track of room noise with a burst at each of `claps_ms`, stamped from `start_ms` in
// 10 ms buffers as a device would.
static void synth(Track* t, double seconds, double start_ms, const double* claps_ms, int claps, double level) {
    track_init(t, seconds);
    for (size_t i = 0; i < (size_t)(seconds * RATE); i++) {
        if (i % 480 == 0) {
            t->buffer_ns[t->buffers] = 1e12 + start_ms * 1e6 + i * 1e9 / RATE;
            t->buffer_at[t->buffers++] = i;
        }
        double now_ms = start_ms + i * 1000.0 / RATE, s = 0.002;
        for (int c = 0; c < claps; c++) {
            double since = now_ms - claps_ms[c];
            if (since >= 0 && since < 60) s = level * exp(-since / 8.0);
        }
        t->samples[i] = (float)(s * ((double)random() / RAND_MAX * 2 - 1));
    }
    t->count = (size_t)(seconds * RATE);
}

// Generated claps, Remote Display Microphone's 87 ms later and quieter, each track
// stamped from its own start time as two devices are. Then what a real room adds: a
// sound only the reference hears, a clap the microphone misses, and a reference whose
// stamps are late.
static int self_test(void) {
    const double delay = 87.0, seconds = 8;
    const double apart[] = {1000, 2500, 4000, 5500};                       // 1.5 s apart
    const double close[] = {1000, 1900, 2800, 3700, 4600, 5500, 6400};     // 0.9 s apart
    const double knock[] = {400, 1000, 1900, 2800, 3700, 4600, 5500, 6400};
    const double missed[] = {1000, 2800, 3700, 4600, 5500, 6400};
    struct {
        const char* name;
        const double *ref, *mic;
        int refs, mics;
        double ref_stamped_late, ref_latency;
        size_t pairs;
        double median;  // the delay expected, or < 0 for "the reference is late"
    } cases[] = {
        {"claps 1.5 s apart", apart, apart, 4, 4, 0, 0, 4, delay},
        {"the reference's input latency is added", apart, apart, 4, 4, 0, 12.5, 4, delay + 12.5},
        {"a knock only the reference hears", knock, close, 8, 7, 0, 0, 7, delay},
        {"a clap the microphone misses", close, missed, 7, 6, 0, 0, 6, delay},
        {"a reference stamped 400 ms late", close, close, 7, 7, 400, 0, 0, -1},
    };
    int failed = 0;
    srandom(7);
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        double ref_ms[8], mic_ms[8];
        for (int i = 0; i < cases[c].refs; i++) ref_ms[i] = cases[c].ref[i] + cases[c].ref_stamped_late;
        for (int i = 0; i < cases[c].mics; i++) mic_ms[i] = cases[c].mic[i] + delay;
        Track ref, mic;
        synth(&ref, seconds, 0, ref_ms, cases[c].refs, 0.8);
        synth(&mic, seconds, 37.3, mic_ms, cases[c].mics, 0.4);
        printf("%s:\n", cases[c].name);
        double median;
        bool late;
        size_t n = compare(&ref, &mic, cases[c].ref_latency, &median, &late);
        bool ok = cases[c].median < 0 ? late : !late && n == cases[c].pairs && fabs(median - cases[c].median) < 1.5;
        if (cases[c].median < 0) printf("%s: the reference %s as late\n", ok ? "PASS" : "FAIL", late ? "shows" : "doesn't show");
        else printf("%s: %zu claps paired, median %.1f ms for %.1f ms made\n", ok ? "PASS" : "FAIL", n, median, cases[c].median);
        failed += !ok;
    }
    printf(failed ? "%d case(s) failed.\n" : "All cases passed.\n", failed);
    return failed ? 1 : 0;
}

// Says how many buffers a recording lost, and whether it has anything left to time.
static bool usable(const Track* t, const char* name) {
    if (t->untimed || t->unkept)
        printf("%s: %zu buffers came without a host time and %zu after the recording was full; %zu kept\n", name,
               t->untimed, t->unkept, t->buffers);
    if (!t->buffers) printf("FAIL: nothing usable was recorded from %s\n", name);
    return t->buffers > 0;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        ns_per_tick = (double)tb.numer / tb.denom;
        NSString* want = nil;
        double seconds = 15;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--self-test")) return self_test();
            if (!strcmp(argv[i], "--list")) {
                for (NSArray* dev in inputs()) {
                    BOOL wired;
                    NSString* how = transport([dev[2] unsignedIntValue], &wired);
                    printf("%s  (%s)  %s\n", [dev[0] UTF8String], [dev[1] UTF8String], how.UTF8String);
                }
                return 0;
            }
            if (!strcmp(argv[i], "--ref") && i + 1 < argc) want = @(argv[++i]);
            else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
            else {
                printf("usage: rd-clap [--list | --self-test | --ref NAME] [--seconds N]\n");
                return 2;
            }
        }
        NSString *ref_uid = nil, *ref_name = nil, *ref_how = nil;
        AudioObjectID ref_dev = kAudioObjectUnknown;
        BOOL mic_found = NO, ref_wired = NO;
        for (NSArray* dev in inputs()) {
            if ([dev[1] isEqualToString:@MIC_UID]) { mic_found = YES; continue; }
            BOOL wired;
            NSString* how = transport([dev[2] unsignedIntValue], &wired);
            // Named: the first match, whatever it is. Not named: the first that's built in or wired.
            if (ref_uid || !(want ? [dev[0] rangeOfString:want options:NSCaseInsensitiveSearch].length > 0 : wired)) continue;
            ref_name = dev[0];
            ref_uid = dev[1];
            ref_dev = [dev[2] unsignedIntValue];
            ref_how = how;
            ref_wired = wired;
        }
        if (!mic_found) { printf("Remote Display Microphone isn't installed\n"); return 2; }
        if (!ref_uid) {
            if (want) printf("No reference input named %s\n", want.UTF8String);
            else printf("No built-in or wired input to use as the reference. Plug one in, or name another with --ref.\n");
            return 2;
        }

        dispatch_semaphore_t asked = dispatch_semaphore_create(0);
        __block BOOL allowed = NO;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            allowed = granted;
            dispatch_semaphore_signal(asked);
        }];
        dispatch_semaphore_wait(asked, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
        if (!allowed) { printf("No microphone access for rd-clap\n"); return 2; }

        Track ref, mic;
        track_init(&ref, seconds);
        track_init(&mic, seconds);
        double ref_latency = input_latency_ms(ref_dev);
        printf("Reference: %s (%s), which reports %.1f ms of input latency. Recording %.0f s\n", ref_name.UTF8String,
               ref_how.UTF8String, ref_latency, seconds);
        if (!ref_wired) printf("Warning: a %s input can stamp its samples late, which shortens or breaks the delays.\n", ref_how.UTF8String);
        fflush(stdout);
        AudioQueueRef qr = record(&ref, ref_uid), qm = record(&mic, @MIC_UID);
        // The queues call back on their own threads; the main thread only waits.
        [NSThread sleepForTimeInterval:seconds];
        AudioQueueStop(qr, true);
        AudioQueueStop(qm, true);

        bool ref_ok = usable(&ref, ref_name.UTF8String), mic_ok = usable(&mic, "Remote Display Microphone");
        if (!ref_ok || !mic_ok) return 2;
        double median;
        bool ref_late;
        size_t n = compare(&ref, &mic, ref_latency, &median, &ref_late);
        if (ref_late) {
            printf("FAIL: Remote Display Microphone heard most claps before %s did, so its time stamps are late. "
                   "Use a built-in or wired reference.\n", ref_name.UTF8String);
            return 2;
        }
        if (n < 3) {
            printf("FAIL: %zu claps heard in both; need 3. Is the controller's microphone on, and the reference near it?\n", n);
            return 1;
        }
        printf("%s: median %.1f ms over %zu claps (the spec's limit is %.0f ms)\n",
               median < LIMIT_MS ? "PASS" : "FAIL", median, n, LIMIT_MS);
        return median < LIMIT_MS ? 0 : 1;
    }
}
