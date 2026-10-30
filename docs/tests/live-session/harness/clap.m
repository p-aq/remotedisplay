// rd-clap: how long a controller's microphone takes to reach Remote Display Microphone
// (spec, Testing plan › Mic latency: under 150 ms on a LAN). Runs on the host while a
// controller forwards its microphone, and records two inputs at once: a reference
// microphone next to the controller's, and Remote Display Microphone. For each clap it
// reports the time between its onset in each, from the host time Core Audio stamps on
// every buffer.
//
//   rd-clap --list                   the inputs
//   rd-clap [--ref NAME] [--seconds N]
//   rd-clap --self-test              the onset detection on generated claps; no microphone
//
// Needs microphone access, so the Makefile runs it as rd-clap.app.
#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <math.h>
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
} Track;

static double ns_per_tick;

static void track_init(Track* t, double seconds) {
    t->capacity = (size_t)(seconds * RATE) + 4800;
    t->samples = calloc(t->capacity, sizeof(float));
    t->buffer_capacity = t->capacity / 64;
    t->buffer_ns = calloc(t->buffer_capacity, sizeof(double));
    t->buffer_at = calloc(t->buffer_capacity, sizeof(size_t));
    t->count = t->buffers = 0;
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

// Pairs each reference clap with the first Remote Display Microphone clap after it and
// prints the delays. Returns how many were paired and their median.
static size_t compare(const Track* ref, const Track* mic, double* median) {
    double r[256], m[256], delays[256];
    float ref_loudest, mic_loudest;
    size_t nr = onsets(ref, r, 256, &ref_loudest), nm = onsets(mic, m, 256, &mic_loudest), n = 0;
    printf("Claps heard: %zu by the reference (loudest %.3f), %zu in Remote Display Microphone (loudest %.3f)\n",
           nr, ref_loudest, nm, mic_loudest);
    for (size_t i = 0, j = 0; i < nr; i++) {
        while (j < nm && m[j] < r[i]) j++;
        if (j == nm) break;
        double ms = (m[j] - r[i]) / 1e6;
        if (ms > MAX_DELAY_MS) continue;
        printf("  clap %zu: %.1f ms\n", n + 1, ms);
        delays[n++] = ms;
        j++;
    }
    for (size_t i = 1; i < n; i++)  // insertion sort; a few dozen at most
        for (size_t k = i; k > 0 && delays[k - 1] > delays[k]; k--) {
            double x = delays[k]; delays[k] = delays[k - 1]; delays[k - 1] = x;
        }
    *median = n ? (n % 2 ? delays[n / 2] : (delays[n / 2 - 1] + delays[n / 2]) / 2) : 0;
    return n;
}

static void on_input(void* user, AudioQueueRef q, AudioQueueBufferRef buf, const AudioTimeStamp* start,
                     UInt32 packets, const AudioStreamPacketDescription* desc) {
    (void)packets; (void)desc;
    Track* t = user;
    size_t n = buf->mAudioDataByteSize / sizeof(float);
    if ((start->mFlags & kAudioTimeStampHostTimeValid) && t->count + n <= t->capacity &&
        t->buffers < t->buffer_capacity) {
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

static BOOL has_input(AudioObjectID dev) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    return !AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) && size > 0;
}

// Input devices as {name, uid}, the default input first.
static NSArray<NSArray<NSString*>*>* inputs(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    AudioObjectID devs[size / sizeof(AudioObjectID) + 1];
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);
    AudioObjectPropertyAddress d = {kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID def = kAudioObjectUnknown;
    UInt32 dsize = sizeof def;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &d, 0, NULL, &dsize, &def);
    NSMutableArray* out = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        if (!has_input(devs[i])) continue;
        NSArray* entry = @[ prop_string(devs[i], kAudioObjectPropertyName), prop_string(devs[i], kAudioDevicePropertyDeviceUID) ];
        if (devs[i] == def) [out insertObject:entry atIndex:0]; else [out addObject:entry];
    }
    return out;
}

// Claps 1.5 s apart in both tracks, Remote Display Microphone's `delay_ms` later and
// quieter, each track stamped from its own start time as two devices would be.
static int self_test(void) {
    const double delay_ms = 87.0, seconds = 8;
    Track ref, mic;
    track_init(&ref, seconds);
    track_init(&mic, seconds);
    double start[2] = {1e12, 1e12 + 37.3e6};
    Track* tracks[2] = {&ref, &mic};
    srandom(7);
    for (int k = 0; k < 2; k++) {
        Track* t = tracks[k];
        for (size_t i = 0; i < (size_t)(seconds * RATE); i++) {
            if (i % 480 == 0) {
                t->buffer_ns[t->buffers] = start[k] + i * 1e9 / RATE;
                t->buffer_at[t->buffers++] = i;
            }
            double now_ms = (start[k] - start[0]) / 1e6 + i * 1000.0 / RATE, s = 0.002;
            for (int c = 0; c < 4; c++) {
                double since = now_ms - (1000.0 + 1500.0 * c + (k ? delay_ms : 0));
                if (since >= 0 && since < 60) s = (k ? 0.4 : 0.8) * exp(-since / 8.0);
            }
            t->samples[i] = (float)(s * ((double)random() / RAND_MAX * 2 - 1));
        }
        t->count = (size_t)(seconds * RATE);
    }
    double median;
    size_t n = compare(&ref, &mic, &median);
    int ok = n == 4 && fabs(median - delay_ms) < 1.5;
    printf("%s: %zu claps paired, median %.1f ms for %.1f ms made\n", ok ? "PASS" : "FAIL", n, median, delay_ms);
    return ok ? 0 : 1;
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
                for (NSArray* dev in inputs()) printf("%s  (%s)\n", [dev[0] UTF8String], [dev[1] UTF8String]);
                return 0;
            }
            if (!strcmp(argv[i], "--ref") && i + 1 < argc) want = @(argv[++i]);
            else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
            else {
                printf("usage: rd-clap [--list | --self-test | --ref NAME] [--seconds N]\n");
                return 2;
            }
        }
        NSString *ref_uid = nil, *ref_name = nil;
        BOOL mic_found = NO;
        for (NSArray* dev in inputs()) {
            if ([dev[1] isEqualToString:@MIC_UID]) { mic_found = YES; continue; }
            if (!ref_uid && (!want || [dev[0] rangeOfString:want options:NSCaseInsensitiveSearch].length)) {
                ref_name = dev[0];
                ref_uid = dev[1];
            }
        }
        if (!mic_found) { printf("Remote Display Microphone isn't installed\n"); return 2; }
        if (!ref_uid) { printf("No reference input%s%s\n", want ? " named " : "", want ? want.UTF8String : ""); return 2; }

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
        printf("Reference: %s. Recording %.0f s\n", ref_name.UTF8String, seconds);
        fflush(stdout);
        AudioQueueRef qr = record(&ref, ref_uid), qm = record(&mic, @MIC_UID);
        // The queues call back on their own threads; the main thread only waits.
        [NSThread sleepForTimeInterval:seconds];
        AudioQueueStop(qr, true);
        AudioQueueStop(qm, true);

        double median;
        size_t n = compare(&ref, &mic, &median);
        if (n < 3) {
            printf("FAIL: %zu claps heard in both; need 3. Is the controller's microphone on, and the reference near it?\n", n);
            return 1;
        }
        printf("%s: median %.1f ms over %zu claps (the spec's limit is %.0f ms)\n",
               median < LIMIT_MS ? "PASS" : "FAIL", median, n, LIMIT_MS);
        return median < LIMIT_MS ? 0 : 1;
    }
}
