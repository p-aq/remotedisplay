// Makes audio appear as "Remote Display Microphone", an input device other apps can pick.
// Harness version of the planned engine code behind the host's mic routing (spec: Host
// side › Microphone; decisions 0008, 0013). Two implementations of the same idea:
//
//   Option A: play into the hidden output-only device of the Remote Display Microphone
//             driver (a BlackHole build); its input-only twin is what apps read.
//   Option B: play into the default output, tap this process's own output with a Core
//             Audio process tap, and publish an aggregate device with the tap as input.
//
// The caller supplies the audio through a render callback, called on the real-time
// I/O thread. In Phase 2 that callback reads the low-latency jitter buffer; here it
// synthesises a test signal.

#pragma once

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacMicSink MacMicSink;

// Fill `frames` interleaved Float32 frames of `channels` channels. `hostTimeNs` is the
// host time at which the first frame reaches the device. Must not block or allocate.
typedef void (*MacMicRender)(void* ctx, float* interleaved, uint32_t frames, uint32_t channels,
                             double sampleRate, uint64_t hostTimeNs);

// CATapMuteBehavior values, without needing the Objective-C header.
enum { kMacMicTapUnmuted = 0, kMacMicTapMuted = 1, kMacMicTapMutedWhenTapped = 2 };

// Option A: `feederUID` is the hidden output device's UID.
MacMicSink* MacMicSinkOpenDriver(const char* feederUID, MacMicRender render, void* ctx, OSStatus* status);

// Option B: creates a public tap of this process and a public aggregate device named
// `micName` with UID `micUID`. With `withOutputSubdevice`, the aggregate also contains
// the default output device as its clock (Apple's sample does this), which gives it
// output channels too.
MacMicSink* MacMicSinkOpenTap(const char* micName, const char* micUID, int muteBehavior,
                              bool withOutputSubdevice, MacMicRender render, void* ctx, OSStatus* status);

// Where the sink plays and, for Option B, the aggregate it published.
AudioObjectID MacMicSinkOutputDevice(MacMicSink* sink);
AudioObjectID MacMicSinkAggregateDevice(MacMicSink* sink);

void MacMicSinkClose(MacMicSink* sink);

// Prints every audio device: id, name, UID, input and output channels, hidden flag.
void MacMicLogDevices(void);

// Finds a device by name that has channels in the given direction; kAudioObjectUnknown if none.
AudioObjectID MacMicFindDevice(const char* name, bool input);

#ifdef __cplusplus
}
#endif
