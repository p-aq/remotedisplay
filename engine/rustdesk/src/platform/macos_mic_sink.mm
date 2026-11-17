// remotedisplay: the host's side of microphone forwarding (docs/specs/camera-audio-forwarding.md,
// Host side › Microphone; decisions 0013, 0015 and 0021). Plays audio into the hidden,
// output-only twin of the Remote Display Microphone driver, which the driver mirrors into
// the visible, input-only device that apps read. With nothing playing, that device reads
// silence.
//
// This is Option A of docs/tests/virtual-mic/harness/mic_sink.mm, moved here unchanged in
// behaviour; Option B (the tap) stays in the harness as the documented fallback. Same
// shape and flags as macos.mm: extern "C" functions named Mac…, -std=c++17, no ARC.
// Called from macos_mic_sink.rs, whose render callback reads the jitter buffer.

#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// Fill `frames` interleaved Float32 frames of `channels` channels. `hostTimeNs` is the
// host time at which the first frame reaches the device. Called on the real-time I/O
// thread: must not block or allocate.
typedef void (*MacMicRender)(void* ctx, float* interleaved, uint32_t frames, uint32_t channels,
                             double sampleRate, uint64_t hostTimeNs);

struct MacMicSink {
    AudioDeviceID device = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = NULL;
    MacMicRender render = NULL;
    void* ctx = NULL;
    double rate = 0;
};

namespace {

AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

UInt32 ChannelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr = Address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, NULL, &size) != noErr || size == 0) return 0;
    std::vector<uint8_t> storage(size);
    AudioBufferList* list = (AudioBufferList*)storage.data();
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, list) != noErr) return 0;
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) channels += list->mBuffers[i].mNumberChannels;
    return channels;
}

// Hidden devices aren't in kAudioHardwarePropertyDevices; only their UID finds them.
AudioObjectID DeviceForUID(const char* uid) {
    CFStringRef cfuid = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (!cfuid) return kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = Address(kAudioHardwarePropertyTranslateUIDToDevice);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(cfuid), &cfuid, &size, &device);
    CFRelease(cfuid);
    return device;
}

double NominalRate(AudioObjectID device) {
    AudioObjectPropertyAddress addr = Address(kAudioDevicePropertyNominalSampleRate);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &rate) != noErr) return 0;
    return rate;
}

uint64_t HostTicksToNs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return ticks * tb.numer / tb.denom;
}

// Starts an I/O proc on `sink->device` that renders into its output buffers. The first
// buffer is rendered; any further buffers (non-interleaved layouts) get a copy, so the
// callback is called exactly once per I/O cycle, as a jitter buffer needs.
OSStatus StartOutput(MacMicSink* sink) {
    sink->rate = NominalRate(sink->device);
    OSStatus err = AudioDeviceCreateIOProcIDWithBlock(
        &sink->proc, sink->device, NULL,
        ^(const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*, AudioBufferList* out,
          const AudioTimeStamp* outTime) {
            if (!out || out->mNumberBuffers == 0) return;
            AudioBuffer& first = out->mBuffers[0];
            UInt32 channels = first.mNumberChannels ? first.mNumberChannels : 1;
            UInt32 frames = first.mDataByteSize / (sizeof(float) * channels);
            uint64_t host = (outTime->mFlags & kAudioTimeStampHostTimeValid) ? HostTicksToNs(outTime->mHostTime)
                                                                             : HostTicksToNs(mach_absolute_time());
            sink->render(sink->ctx, (float*)first.mData, frames, channels, sink->rate, host);
            for (UInt32 b = 1; b < out->mNumberBuffers; b++) {
                AudioBuffer& other = out->mBuffers[b];
                if (other.mDataByteSize == first.mDataByteSize) memcpy(other.mData, first.mData, first.mDataByteSize);
                else memset(other.mData, 0, other.mDataByteSize);
            }
        });
    if (err != noErr) return err;
    return AudioDeviceStart(sink->device, sink->proc);
}

}  // namespace

extern "C" void MacMicSinkClose(MacMicSink* sink);

// Whether the feeder device exists, and its format: what the render callback will be
// asked for.
extern "C" bool MacMicFeederFormat(const char* feederUID, double* rate, uint32_t* channels) {
    AudioObjectID device = DeviceForUID(feederUID);
    if (device == kAudioObjectUnknown) return false;
    UInt32 out = ChannelCount(device, kAudioObjectPropertyScopeOutput);
    if (out == 0) return false;
    if (rate) *rate = NominalRate(device);
    if (channels) *channels = out;
    return true;
}

// `feederUID` is the hidden output device's UID. The render callback starts before this
// returns, and isn't called once MacMicSinkClose returns.
extern "C" MacMicSink* MacMicSinkOpenDriver(const char* feederUID, MacMicRender render, void* ctx, OSStatus* status) {
    MacMicSink* sink = new MacMicSink();
    sink->render = render;
    sink->ctx = ctx;
    sink->device = DeviceForUID(feederUID);
    OSStatus err = noErr;
    if (sink->device == kAudioObjectUnknown) err = kAudioHardwareBadDeviceError;
    else if (ChannelCount(sink->device, kAudioObjectPropertyScopeOutput) == 0) err = kAudioHardwareUnsupportedOperationError;
    else err = StartOutput(sink);
    if (status) *status = err;
    if (err != noErr) {
        MacMicSinkClose(sink);
        return NULL;
    }
    return sink;
}

extern "C" void MacMicSinkClose(MacMicSink* sink) {
    if (!sink) return;
    if (sink->proc) {
        // Called off the I/O thread, this returns once the I/O proc won't be called again.
        AudioDeviceStop(sink->device, sink->proc);
        AudioDeviceDestroyIOProcID(sink->device, sink->proc);
    }
    delete sink;
}
