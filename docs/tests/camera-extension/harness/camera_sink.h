// Feeds pixel buffers into Remote Display Camera's sink stream.
// Harness copy of the planned engine file src/platform/macos_camera_sink.mm.

#pragma once

#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacCameraSink MacCameraSink;

enum {
    kMacCameraSinkQueued = 0,
    kMacCameraSinkDropped = 1,  // the extension hasn't drained the queue yet
    kMacCameraSinkError = -1,
};

// Finds the device named `deviceName` and starts its sink stream, waiting up to
// `timeoutSeconds` for the extension to publish it. NULL on failure, with `status` set.
MacCameraSink* MacCameraSinkOpen(const char* deviceName, double timeoutSeconds, OSStatus* status);

// Enqueues one frame. Never blocks: when the queue is full the frame is dropped.
int MacCameraSinkPush(MacCameraSink* sink, CVPixelBufferRef pixelBuffer, int32_t fps);

uint32_t MacCameraSinkQueueCapacity(MacCameraSink* sink);

void MacCameraSinkClose(MacCameraSink* sink);

// Prints every CoreMediaIO device and its streams to stdout (diagnostics).
void MacCameraSinkLogDevices(void);

#ifdef __cplusplus
}
#endif
