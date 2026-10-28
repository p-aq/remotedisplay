# 0004. Encode the controller's camera with `VTCompressionSession`

- **Status:** Accepted, 2026-10-24 (review finding V-1, V-2; PR #16)
- **Original design:** Departs from the spec, which handed camera buffers to the
  encoder hwcodec wraps, behind `TraitCapturer`. Follows the engine's pattern for macOS
  code: an `.mm` file with `extern "C"` `Mac…` functions.

## Context

`HwRamEncoder::encode` takes one contiguous CPU buffer in FFmpeg's layout;
`quartz::PixelBuffer` is BGRA only; `convert_to_yuv` rejects NV12. A camera's NV12
`CVPixelBuffer` would be copied into FFmpeg's layout and then copied again into a new
`CVPixelBuffer`. `EncoderApi` also has no call to force a key frame or change bitrate
on a running encoder; the screen path rebuilds the encoder instead.

## Decision

A new `src/platform/macos_camera_capture.mm` captures with `AVCaptureSession` (NV12,
`alwaysDiscardsLateVideoFrames`) and encodes with `VTCompressionSession`: real time, no
frame reordering, `kVTEncodeFrameOptionKey_ForceKeyFrame` per frame, live
`AverageBitRate` and `DataRateLimits`. It mirrors the host's `macos_camera_sink.mm`.
hwcodec stays for Phase 4 (Windows).

## Consequences

- Zero-copy capture to encode, and key frame and bitrate control without rebuilding.
- One more `.mm` in `src/platform/`, listed in `engine/SYNC.md`.
- The hwcodec check on a controller-only Mac (finding V-3) doesn't matter for camera.

## Measured (2026-10-24)

`docs/tests/camera-extension/` (`make codec-test`) confirms the decision on an Apple M4:
`VTCompressionSession` takes the NV12 IOSurface buffers directly, forces key frames per
frame, changes bitrate live (2,000 → 500 kbit/s tracked within 3%), and encodes a 720p
frame in about 5 ms. Encoder mode and fallbacks: decision 0016.

## Implementation (2026-10-27)

`src/platform/macos_camera_capture.mm`, wrapped by `macos_camera_capture.rs` in the
same folder (`HOOKS.md` E5). It compiles as its own `cc` library next to `macos.mm`,
with the same flags. Tested with a USB camera in `docs/tests/camera-capture/`: 720p at
29.8 fps, and the host's decoder decodes every unit.

- **Encoder:** the harness encoder, unchanged in behaviour (decision 0016). The
  encoder is created after the camera starts, at the size the camera actually
  delivers. A frame of any other size is dropped and counted, so the encoder never
  scales.
- **Format:** the camera's own format closest in area to the request, up to the
  host's 1920×1080, preferring one that reaches the frame rate. The frame duration
  is one the format lists, because USB cameras often offer only fixed rates and any
  other value throws.
- **The one-frame slot (decision 0006)** holds at most one frame inside the encoder.
  A frame that arrives while the encoder is busy is dropped before encoding. The
  sender's backlog rule gets `set_skipping()`, and frames it has to drop after
  encoding get `request_key_frame()`.
- **Listing:** cameras are listed without Remote Display Camera (manufacturer
  "Remote Display"), so a Mac that is both host and controller can't forward its own
  virtual camera back.
- **Client app:** it gains `NSCameraUsageDescription`, `com.apple.security.device.camera`
  and `NSCameraUseContinuityCameraDeviceType`. Without the last one, AVFoundation
  leaves Continuity Camera out of the list.
