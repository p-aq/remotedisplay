// H.264 encode and decode for camera forwarding, with Annex B on the wire.
// Harness version of the planned engine code: the encoder belongs in the controller's
// src/platform/macos_camera_capture.mm (decision 0004), the decoder in front of the
// host's src/platform/macos_camera_sink.mm (decision 0005).

#pragma once

#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Encoder (controller) ----

typedef struct MacCameraEncoder MacCameraEncoder;

// Called once per encoded frame, on VideoToolbox's thread: one access unit in Annex B,
// with SPS and PPS in front when `keyFrame`. The buffer is valid only during the call.
typedef void (*MacCameraEncoded)(void* ctx, const uint8_t* annexB, size_t length, bool keyFrame, int64_t ptsUs);

typedef struct {
    bool lowLatency;        // created with low-latency rate control
    bool requiredHardware;  // created with the hardware encoder required
    char encoderID[128];    // e.g. com.apple.videotoolbox.videoencoder.h264.rtvc
} MacCameraEncoderInfo;

// Real time, no frame reordering, a key frame at least every `keyIntervalSeconds`.
// With `lowLatency`, asks for low-latency rate control (Apple's real-time video
// conferencing encoder). Hardware is required when available; software is the last
// resort, and `info` says which was used.
MacCameraEncoder* MacCameraEncoderCreate(int width, int height, int fps, int bitrateKbps, double keyIntervalSeconds,
                                         bool lowLatency, MacCameraEncoded callback, void* ctx,
                                         MacCameraEncoderInfo* info, OSStatus* status);

OSStatus MacCameraEncoderEncode(MacCameraEncoder* encoder, CVPixelBufferRef frame, int64_t ptsUs, bool forceKeyFrame);

// Changes the target bitrate of the running encoder (CameraControl.target_bitrate_kbps).
OSStatus MacCameraEncoderSetBitrate(MacCameraEncoder* encoder, int bitrateKbps);

void MacCameraEncoderDestroy(MacCameraEncoder* encoder);

// ---- Decoder (host) ----

typedef struct MacCameraDecoder MacCameraDecoder;

enum {
    kMacCameraDecoded = 0,        // *out holds a new frame (+1 reference)
    kMacCameraNeedKeyFrame = 1,   // nothing to show until a key frame arrives; ask for one
    kMacCameraRejected = 2,       // malformed or out of limits; dropped, ask for a key frame
};

// Limits checked before anything reaches VideoToolbox.
#define kMacCameraMaxAccessUnitBytes (4 * 1024 * 1024)
#define kMacCameraMaxWidth 1920
#define kMacCameraMaxHeight 1080

MacCameraDecoder* MacCameraDecoderCreate(OSStatus* status);

// Decodes one Annex B access unit into an NV12 IOSurface-backed pixel buffer.
int MacCameraDecoderDecode(MacCameraDecoder* decoder, const uint8_t* data, size_t length, int64_t ptsUs,
                           CVPixelBufferRef* out);

void MacCameraDecoderDestroy(MacCameraDecoder* decoder);

#ifdef __cplusplus
}
#endif
