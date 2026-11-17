// rd-mic-feeder: makes "Remote Display Microphone" carry a test signal, the way
// remotedisplayd will carry a controller's voice (Option A or B, see mic_sink.h).
//
// The signal is a 50 ms tone burst starting at every whole second of host time, so
// rd-mic-probe, in another process, can measure latency on the same clock without
// talking to this one.
//
// usage: rd-mic-feeder --option a|b [--mute muted|when-tapped|unmuted]
//                      [--with-output-subdevice] [--seconds N] [--tone HZ] [--level 0-1] [--list]

#include "mic_sink.h"

#include <dispatch/dispatch.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* kMicName = "Remote Display Microphone";
static const char* kTapMicUID = "app.remotedisplay.spike.mic.tap";
// The driver's hidden output-only twin: kDriver_Name "_2_UID" (see Makefile).
static const char* kDriverFeederUID = "RemoteDisplayMicrophone_2_UID";
static const double kBurstSeconds = 0.05;

struct Tone {
    double freq;
    double level;
};

static void RenderBursts(void* ctx, float* out, uint32_t frames, uint32_t channels, double rate, uint64_t hostNs) {
    const Tone* tone = (const Tone*)ctx;
    double t0 = hostNs / 1e9;
    for (uint32_t i = 0; i < frames; i++) {
        double t = t0 + i / rate;
        float v = fmod(t, 1.0) < kBurstSeconds ? (float)(tone->level * sin(2 * M_PI * tone->freq * t)) : 0.0f;
        for (uint32_t c = 0; c < channels; c++) out[i * channels + c] = v;
    }
}

static void Usage(int code) {
    fprintf(code ? stderr : stdout,
            "usage: rd-mic-feeder --option a|b [--mute muted|when-tapped|unmuted] [--with-output-subdevice]\n"
            "                     [--seconds N] [--tone HZ] [--level 0-1] [--list]\n");
    exit(code);
}

int main(int argc, char** argv) {
    char option = 0;
    int mute = kMacMicTapMuted;
    bool withOutput = false;
    double seconds = 0;
    static Tone tone = {1000, 0.3};
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        bool hasValue = i + 1 < argc;
        if (!strcmp(a, "--list")) {
            MacMicLogDevices();
            return 0;
        } else if (!strcmp(a, "--option") && hasValue) {
            option = argv[++i][0] | 0x20;  // lower case
        } else if (!strcmp(a, "--mute") && hasValue) {
            const char* m = argv[++i];
            if (!strcmp(m, "muted")) mute = kMacMicTapMuted;
            else if (!strcmp(m, "when-tapped")) mute = kMacMicTapMutedWhenTapped;
            else if (!strcmp(m, "unmuted")) mute = kMacMicTapUnmuted;
            else Usage(1);
        } else if (!strcmp(a, "--with-output-subdevice")) {
            withOutput = true;
        } else if (!strcmp(a, "--seconds") && hasValue) {
            seconds = atof(argv[++i]);
        } else if (!strcmp(a, "--tone") && hasValue) {
            tone.freq = atof(argv[++i]);
        } else if (!strcmp(a, "--level") && hasValue) {
            tone.level = atof(argv[++i]);
        } else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            Usage(0);
        } else {
            Usage(1);
        }
    }
    if (option != 'a' && option != 'b') Usage(1);

    OSStatus status = noErr;
    MacMicSink* sink = option == 'a'
        ? MacMicSinkOpenDriver(kDriverFeederUID, RenderBursts, &tone, &status)
        : MacMicSinkOpenTap(kMicName, kTapMicUID, mute, withOutput, RenderBursts, &tone, &status);
    if (!sink) {
        char fourcc[5] = {0};
        for (int i = 0; i < 4; i++) {
            char c = (char)((status >> (24 - 8 * i)) & 0xff);
            fourcc[i] = (c >= 32 && c < 127) ? c : '?';
        }
        fprintf(stderr, "rd-mic-feeder: option %c failed: OSStatus %d ('%s')%s\n", option, (int)status, fourcc,
                option == 'a' ? "; is the Remote Display Microphone driver installed? (make install-driver)" : "");
        return 1;
    }
    if (option == 'a') {
        printf("option A: playing into the driver's hidden feeder (device %u); apps read \"%s\"\n",
               MacMicSinkOutputDevice(sink), kMicName);
    } else {
        printf("option B: playing into the default output (device %u), mute=%d; published aggregate %u \"%s\" (%s)\n",
               MacMicSinkOutputDevice(sink), mute, MacMicSinkAggregateDevice(sink), kMicName, kTapMicUID);
    }
    printf("signal: %.0f Hz bursts of %.0f ms at every whole second, level %.2f\n", tone.freq, kBurstSeconds * 1000,
           tone.level);
    fflush(stdout);

    static MacMicSink* running = sink;
    void (^stop)(void) = ^{
        MacMicSinkClose(running);
        printf("stopped\n");
        exit(0);
    };
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    dispatch_source_t sigint = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_t sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigint, stop);
    dispatch_source_set_event_handler(sigterm, stop);
    dispatch_resume(sigint);
    dispatch_resume(sigterm);
    if (seconds > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                                    dispatch_get_main_queue(), stop);
    dispatch_main();
}
