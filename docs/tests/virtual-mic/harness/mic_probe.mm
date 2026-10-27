// rd-mic-probe: records from an input device the way Zoom would, and reports whether
// rd-mic-feeder's tone bursts arrive and how late.
//
// Bursts start at every whole second of host time, so each onset's host time modulo
// one second is the latency from the feeder's output to this input.
//
// usage: rd-mic-probe [--list] [--device NAME] [--seconds N] [--threshold X]

#include "mic_sink.h"

#include <algorithm>
#include <atomic>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vector>

static const int kMaxOnsets = 4096;

struct Probe {
    double rate = 48000;
    float threshold = 0.05f;
    // Written on the I/O thread, read after it stops.
    uint64_t onsets[kMaxOnsets];
    std::atomic<int> count{0};
    float peak = 0;
    uint64_t samples = 0, nonZero = 0;
    uint64_t quiet = 0;
    bool armed = false;
};

static uint64_t HostTicksToNs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return ticks * tb.numer / tb.denom;
}

static void Usage(int code) {
    fprintf(code ? stderr : stdout,
            "usage: rd-mic-probe [--list] [--device NAME] [--seconds N] [--threshold X]\n");
    exit(code);
}

int main(int argc, char** argv) {
    const char* name = "Remote Display Microphone";
    double seconds = 10;
    static Probe probe;
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        bool hasValue = i + 1 < argc;
        if (!strcmp(a, "--list")) {
            MacMicLogDevices();
            return 0;
        } else if (!strcmp(a, "--device") && hasValue) {
            name = argv[++i];
        } else if (!strcmp(a, "--seconds") && hasValue) {
            seconds = atof(argv[++i]);
        } else if (!strcmp(a, "--threshold") && hasValue) {
            probe.threshold = (float)atof(argv[++i]);
        } else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            Usage(0);
        } else {
            Usage(1);
        }
    }

    AudioObjectID device = MacMicFindDevice(name, true);
    if (device == kAudioObjectUnknown) {
        fprintf(stderr, "rd-mic-probe: no input device named \"%s\" (try --list)\n", name);
        return 1;
    }
    AudioObjectPropertyAddress rateAddr = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(probe.rate);
    AudioObjectGetPropertyData(device, &rateAddr, 0, NULL, &size, &probe.rate);

    AudioDeviceIOProcID proc = NULL;
    Probe* p = &probe;
    OSStatus err = AudioDeviceCreateIOProcIDWithBlock(
        &proc, device, NULL,
        ^(const AudioTimeStamp*, const AudioBufferList* in, const AudioTimeStamp* inTime, AudioBufferList*,
          const AudioTimeStamp*) {
            if (!in || in->mNumberBuffers == 0) return;
            const AudioBuffer& b = in->mBuffers[0];
            UInt32 channels = b.mNumberChannels ? b.mNumberChannels : 1;
            UInt32 frames = b.mDataByteSize / (sizeof(float) * channels);
            const float* data = (const float*)b.mData;
            uint64_t t0 = HostTicksToNs(inTime->mHostTime);
            uint64_t quietNeeded = (uint64_t)(0.2 * p->rate);
            for (UInt32 i = 0; i < frames; i++) {
                float v = fabsf(data[i * channels]);  // channel 0
                p->samples++;
                if (v != 0) p->nonZero++;
                if (v > p->peak) p->peak = v;
                if (v > p->threshold) {
                    if (p->armed) {
                        int n = p->count.load(std::memory_order_relaxed);
                        if (n < kMaxOnsets) {
                            p->onsets[n] = t0 + (uint64_t)(i * 1e9 / p->rate);
                            p->count.store(n + 1, std::memory_order_release);
                        }
                        p->armed = false;
                    }
                    p->quiet = 0;
                } else if (++p->quiet > quietNeeded) {
                    p->armed = true;
                }
            }
        });
    if (err == noErr) err = AudioDeviceStart(device, proc);
    if (err != noErr) {
        fprintf(stderr, "rd-mic-probe: can't record from \"%s\": OSStatus %d\n", name, (int)err);
        return 1;
    }
    printf("recording \"%s\" (device %u) at %.0f Hz for %.0f s\n", name, device, probe.rate, seconds);
    fflush(stdout);
    usleep((useconds_t)(seconds * 1e6));
    AudioDeviceStop(device, proc);
    AudioDeviceDestroyIOProcID(device, proc);

    int n = probe.count.load(std::memory_order_acquire);
    std::vector<double> latencies;
    for (int i = 0; i < n; i++) latencies.push_back((probe.onsets[i] % 1000000000ULL) / 1e6);
    printf("samples %llu, non-zero %llu, peak %.3f, bursts %d\n", probe.samples, probe.nonZero, probe.peak, n);
    if (!latencies.empty()) {
        std::vector<double> sorted = latencies;
        std::sort(sorted.begin(), sorted.end());
        printf("latency ms: min %.1f, median %.1f, max %.1f\n", sorted.front(), sorted[sorted.size() / 2],
               sorted.back());
    }
    int expected = (int)seconds - 2;
    if (probe.samples == 0) {
        printf("FAIL: the device delivered no audio\n");
        return 2;
    }
    if (probe.nonZero == 0) {
        printf("FAIL: only digital silence (no feeder running, or Microphone permission denied)\n");
        return 2;
    }
    if (n < expected) {
        printf("FAIL: %d bursts, expected at least %d\n", n, expected);
        return 2;
    }
    printf("PASS\n");
    return 0;
}
