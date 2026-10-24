// Harness version of the engine's virtual-mic plumbing; see mic_sink.h.
// Same shape and flags as src/platform/macos.mm: extern "C" functions named Mac…,
// -std=c++17, no ARC (Objective-C objects are released by hand).

#include "mic_sink.h"

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string>
#include <unistd.h>
#include <vector>

struct MacMicSink {
    AudioDeviceID device = kAudioObjectUnknown;  // where the I/O proc plays
    AudioDeviceIOProcID proc = NULL;
    AudioObjectID tap = kAudioObjectUnknown;        // Option B
    AudioObjectID aggregate = kAudioObjectUnknown;  // Option B
    MacMicRender render = NULL;
    void* ctx = NULL;
    double rate = 0;
};

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

static std::string StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = Address(selector);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value) != noErr || !value) return "";
    char buf[512];
    std::string out;
    if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) out = buf;
    CFRelease(value);
    return out;
}

static UInt32 UInt32Property(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = Address(selector);
    UInt32 value = 0, size = sizeof(value);
    AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value);
    return value;
}

static UInt32 ChannelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
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

static std::vector<AudioObjectID> Devices() {
    AudioObjectPropertyAddress addr = Address(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return {};
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids.data());
    return ids;
}

static AudioObjectID DeviceForUID(const char* uid) {
    CFStringRef cfuid = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectPropertyAddress addr = Address(kAudioHardwarePropertyTranslateUIDToDevice);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(cfuid), &cfuid, &size, &device);
    CFRelease(cfuid);
    return device;
}

static uint64_t HostTicksToNs(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return ticks * tb.numer / tb.denom;
}

// Starts an I/O proc on `sink->device` that renders into its output buffers. The first
// buffer is rendered; any further buffers (non-interleaved layouts) get a copy, so the
// callback is called exactly once per I/O cycle, as a jitter buffer needs.
static OSStatus StartOutput(MacMicSink* sink) {
    AudioObjectPropertyAddress rateAddr = Address(kAudioDevicePropertyNominalSampleRate);
    UInt32 size = sizeof(sink->rate);
    AudioObjectGetPropertyData(sink->device, &rateAddr, 0, NULL, &size, &sink->rate);
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

static MacMicSink* Fail(MacMicSink* sink, OSStatus* status, OSStatus err) {
    if (status) *status = err;
    MacMicSinkClose(sink);
    return NULL;
}

extern "C" MacMicSink* MacMicSinkOpenDriver(const char* feederUID, MacMicRender render, void* ctx, OSStatus* status) {
    MacMicSink* sink = new MacMicSink();
    sink->render = render;
    sink->ctx = ctx;
    sink->device = DeviceForUID(feederUID);
    if (sink->device == kAudioObjectUnknown) return Fail(sink, status, kAudioHardwareBadDeviceError);
    if (ChannelCount(sink->device, kAudioObjectPropertyScopeOutput) == 0)
        return Fail(sink, status, kAudioHardwareUnsupportedOperationError);
    OSStatus err = StartOutput(sink);
    if (err != noErr) return Fail(sink, status, err);
    if (status) *status = noErr;
    return sink;
}

extern "C" MacMicSink* MacMicSinkOpenTap(const char* micName, const char* micUID, int muteBehavior,
                                         bool withOutputSubdevice, MacMicRender render, void* ctx, OSStatus* status) {
    MacMicSink* sink = new MacMicSink();
    sink->render = render;
    sink->ctx = ctx;
    sink->device = UInt32Property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
    if (sink->device == kAudioObjectUnknown) return Fail(sink, status, kAudioHardwareBadDeviceError);

    // Play first: this process only gets an audio process object once it does I/O.
    OSStatus err = StartOutput(sink);
    if (err != noErr) return Fail(sink, status, err);
    pid_t pid = getpid();
    AudioObjectID process = kAudioObjectUnknown;
    AudioObjectPropertyAddress pidAddr = Address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    for (int i = 0; i < 50 && process == kAudioObjectUnknown; i++) {
        UInt32 size = sizeof(process);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &pidAddr, sizeof(pid), &pid, &size, &process);
        if (process == kAudioObjectUnknown) usleep(20000);
    }
    if (process == kAudioObjectUnknown) return Fail(sink, status, kAudioHardwareIllegalOperationError);

    CATapDescription* desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(process) ]];
    desc.name = [NSString stringWithFormat:@"%s tap", micName];
    desc.privateTap = NO;  // other processes (Zoom) read the aggregate built on it
    desc.muteBehavior = (CATapMuteBehavior)muteBehavior;
    NSString* tapUID = [[desc.UUID UUIDString] retain];
    err = AudioHardwareCreateProcessTap(desc, &sink->tap);
    [desc release];
    if (err != noErr) {
        [tapUID release];
        return Fail(sink, status, err);
    }

    NSMutableDictionary* agg = [NSMutableDictionary dictionary];
    agg[@kAudioAggregateDeviceNameKey] = @(micName);
    agg[@kAudioAggregateDeviceUIDKey] = @(micUID);
    agg[@kAudioAggregateDeviceIsPrivateKey] = @NO;
    agg[@kAudioAggregateDeviceTapAutoStartKey] = @YES;
    agg[@kAudioAggregateDeviceTapListKey] = @[ @{@kAudioSubTapUIDKey : tapUID, @kAudioSubTapDriftCompensationKey : @YES} ];
    if (withOutputSubdevice) {
        NSString* outUID = @(StringProperty(sink->device, kAudioDevicePropertyDeviceUID).c_str());
        agg[@kAudioAggregateDeviceMainSubDeviceKey] = outUID;
        agg[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{@kAudioSubDeviceUIDKey : outUID} ];
    }
    [tapUID release];
    err = AudioHardwareCreateAggregateDevice((CFDictionaryRef)agg, &sink->aggregate);
    if (err != noErr) return Fail(sink, status, err);
    if (status) *status = noErr;
    return sink;
}

extern "C" AudioObjectID MacMicSinkOutputDevice(MacMicSink* sink) { return sink ? sink->device : kAudioObjectUnknown; }

extern "C" AudioObjectID MacMicSinkAggregateDevice(MacMicSink* sink) {
    return sink ? sink->aggregate : kAudioObjectUnknown;
}

extern "C" void MacMicSinkClose(MacMicSink* sink) {
    if (!sink) return;
    if (sink->proc) {
        AudioDeviceStop(sink->device, sink->proc);
        AudioDeviceDestroyIOProcID(sink->device, sink->proc);
    }
    if (sink->aggregate != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(sink->aggregate);
    if (sink->tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(sink->tap);
    delete sink;
}

extern "C" void MacMicLogDevices(void) {
    for (AudioObjectID d : Devices()) {
        printf("device %u: %s  uid=%s  in=%u out=%u%s\n", d, StringProperty(d, kAudioObjectPropertyName).c_str(),
               StringProperty(d, kAudioDevicePropertyDeviceUID).c_str(), ChannelCount(d, kAudioObjectPropertyScopeInput),
               ChannelCount(d, kAudioObjectPropertyScopeOutput),
               UInt32Property(d, kAudioDevicePropertyIsHidden) ? "  hidden" : "");
    }
}

extern "C" AudioObjectID MacMicFindDevice(const char* name, bool input) {
    for (AudioObjectID d : Devices()) {
        if (StringProperty(d, kAudioObjectPropertyName) != name) continue;
        if (ChannelCount(d, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput) > 0) return d;
    }
    return kAudioObjectUnknown;
}
