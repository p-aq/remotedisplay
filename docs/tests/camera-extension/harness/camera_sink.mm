// Feeds pixel buffers into Remote Display Camera's sink stream through the
// CoreMediaIO C API (sinks have no AVFoundation API).
//
// Harness copy of the planned engine file src/platform/macos_camera_sink.mm
// (spec: Host side; decision 0011). It has the same shape as src/platform/macos.mm:
// extern "C" functions named Mac…, built with -std=c++17 and without ARC, so Phase 1
// moves it into the engine as is and adds the H.264 decode in front (decision 0005).

#include "camera_sink.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <stdio.h>
#include <string>
#include <unistd.h>
#include <vector>

struct MacCameraSink {
    CMIOObjectID device;
    CMIOStreamID stream;
    CMSimpleQueueRef queue;
};

static CMIOObjectPropertyAddress Address(CMIOObjectPropertySelector selector) {
    return {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
}

static std::vector<CMIOObjectID> ObjectList(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CMIOObjectPropertyAddress addr = Address(selector);
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(object, &addr, 0, NULL, &size) != noErr || size == 0) return {};
    std::vector<CMIOObjectID> ids(size / sizeof(CMIOObjectID));
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, size, &used, ids.data()) != noErr) return {};
    ids.resize(used / sizeof(CMIOObjectID));
    return ids;
}

static std::string StringProperty(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CMIOObjectPropertyAddress addr = Address(selector);
    CFStringRef value = NULL;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, sizeof(value), &used, &value) != noErr || !value)
        return "";
    char buf[512];
    std::string out;
    if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) out = buf;
    CFRelease(value);
    return out;
}

static bool HasSuffix(const std::string& s, const char* suffix) {
    size_t n = strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

static bool FindSink(const char* deviceName, CMIOObjectID* device, CMIOStreamID* stream) {
    for (CMIOObjectID d : ObjectList(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)) {
        if (StringProperty(d, kCMIOObjectPropertyName) != deviceName) continue;
        std::vector<CMIOObjectID> streams = ObjectList(d, kCMIODevicePropertyStreams);
        // The extension names its sink "<device> Sink"; fall back to the second
        // stream, the order the extension adds them in.
        for (CMIOObjectID s : streams) {
            if (HasSuffix(StringProperty(s, kCMIOObjectPropertyName), " Sink")) {
                *device = d;
                *stream = s;
                return true;
            }
        }
        if (streams.size() > 1) {
            *device = d;
            *stream = streams[1];
            return true;
        }
    }
    return false;
}

static void QueueAltered(CMIOStreamID, void*, void*) {}

extern "C" MacCameraSink* MacCameraSinkOpen(const char* deviceName, double timeoutSeconds, OSStatus* status) {
    CMIOObjectID device = 0;
    CMIOStreamID stream = 0;
    // Camera extensions are published asynchronously; poll until the device shows up.
    bool found = false;
    for (double waited = 0; !(found = FindSink(deviceName, &device, &stream)) && waited < timeoutSeconds; waited += 0.1)
        usleep(100000);
    if (!found) {
        if (status) *status = kCMIOHardwareBadDeviceError;
        return NULL;
    }
    CMSimpleQueueRef queue = NULL;
    OSStatus err = CMIOStreamCopyBufferQueue(stream, QueueAltered, NULL, &queue);
    if (err != noErr || !queue) {
        if (status) *status = err ? err : kCMIOHardwareUnspecifiedError;
        return NULL;
    }
    err = CMIODeviceStartStream(device, stream);
    if (err != noErr) {
        CFRelease(queue);
        if (status) *status = err;
        return NULL;
    }
    if (status) *status = noErr;
    return new MacCameraSink{device, stream, queue};
}

extern "C" int MacCameraSinkPush(MacCameraSink* sink, CVPixelBufferRef pixelBuffer, int32_t fps) {
    if (!sink || !pixelBuffer) return kMacCameraSinkError;
    // Drop rather than queue latency: the extension drains the sink continuously.
    if (CMSimpleQueueGetCount(sink->queue) >= CMSimpleQueueGetCapacity(sink->queue)) return kMacCameraSinkDropped;
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr)
        return kMacCameraSinkError;
    CMSampleTimingInfo timing = {CMTimeMake(1, fps > 0 ? fps : 30), CMClockGetTime(CMClockGetHostTimeClock()),
                                 kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format, &timing, &sample);
    CFRelease(format);
    if (err != noErr || !sample) return kMacCameraSinkError;
    // The queue takes this reference; CoreMediaIO releases it once the extension consumes it.
    if (CMSimpleQueueEnqueue(sink->queue, sample) != noErr) {
        CFRelease(sample);
        return kMacCameraSinkDropped;
    }
    return kMacCameraSinkQueued;
}

extern "C" uint32_t MacCameraSinkQueueCapacity(MacCameraSink* sink) {
    return sink ? (uint32_t)CMSimpleQueueGetCapacity(sink->queue) : 0;
}

extern "C" void MacCameraSinkClose(MacCameraSink* sink) {
    if (!sink) return;
    CMIODeviceStopStream(sink->device, sink->stream);
    CFRelease(sink->queue);
    delete sink;
}

extern "C" void MacCameraSinkLogDevices(void) {
    for (CMIOObjectID d : ObjectList(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)) {
        printf("device %u: %s  uid=%s\n", d, StringProperty(d, kCMIOObjectPropertyName).c_str(),
               StringProperty(d, kCMIODevicePropertyDeviceUID).c_str());
        for (CMIOObjectID s : ObjectList(d, kCMIODevicePropertyStreams)) {
            CMIOObjectPropertyAddress addr = Address(kCMIOStreamPropertyDirection);
            UInt32 direction = 0, used = 0;
            CMIOObjectGetPropertyData(s, &addr, 0, NULL, sizeof(direction), &used, &direction);
            printf("  stream %u: %s  direction=%u\n", s, StringProperty(s, kCMIOObjectPropertyName).c_str(), direction);
        }
    }
}
