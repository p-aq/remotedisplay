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
