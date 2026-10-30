# 0016. Camera encoder settings and decoder contract

- **Status:** Accepted, 2026-10-24, on the codec measurements in
  `docs/tests/camera-extension/` (issue #2).
- **Original design:** Extends decisions 0004 and 0005, which chose VideoToolbox and
  Annex B but not the encoder mode, the decoder's limits or how it reports trouble.
  Follows the spec's security row ("validate every width, height and frame rate before
  use … drop bad frames; fuzz the new messages").

## Context

- Asking VideoToolbox for low-latency rate control selects a different encoder,
  `h264.rtvc`, Apple's real-time conferencing encoder. It doesn't report
  `UsingHardwareAcceleratedVideoEncoder`, and a software variant, `h264.rtvc.sw`, exists.
- Against the standard hardware encoder (`ave.avc`) on the same input, `h264.rtvc` gave
  60 dB median luma PSNR against 50 dB at 2 Mbit/s, with a 5.1 ms median encode latency
  against 5.6 ms. Both forced key frames on demand and followed a live bitrate change.
- The host decodes bytes that arrive from the network. The FreeRDP CVE in the spec
  came from one unchecked field.

## Decision

**Encoder (controller):**

- Create the session with low-latency rate control and the hardware encoder
  **required**, falling back in order to low-latency only, hardware only, then
  neither, and log which one was used (`EncoderID`).
- Real time, no frame reordering, a key frame at least every 2 s; `AverageBitRate` plus
  `DataRateLimits` of 1.5× the target per second; both change live.
- Create the encoder when the camera is switched on: a session's first frame takes
  about 42 ms against about 5 ms afterwards.

**Decoder (host):** one call per access unit, three outcomes:

- `decoded`: a new NV12 IOSurface frame for the sink;
- `need key frame`: nothing to show yet (no parameter sets, or a broken reference
  chain); send `CameraControl.key_frame_request`, rate-limited per decision 0005;
- `rejected`: dropped before or by VideoToolbox; also ask for a key frame.

Before anything reaches VideoToolbox: empty input and access units over 4 MB are
rejected; the stream's size comes from the format description built from SPS/PPS and
must be between 16×16 and 1920×1080. New or changed SPS/PPS rebuild the session.

**Testing:** the decoder's fuzz pass runs under AddressSanitizer and
UndefinedBehaviorSanitizer (`make codec-test-asan`, 20,000 cases) and stays a required
check when the code moves into the engine.

## Consequences

- Better pictures at the same bitrate, without giving up latency.
- The decoder never crashes on bad input, and every failure maps to one host action:
  ask for a key frame.
- Raising the size limit for 1080p+ cameras (Phase 5) is one constant, plus this record.

## In the engine (2026-10-27)

- **The decoder moved** into `src/platform/macos_camera_sink.mm` (`HOOKS.md` E8)
  unchanged, apart from the size limit below. The fuzz pass under the sanitizers now
  runs against the engine's copy: `docs/tests/camera-sink/` (`make test-asan`, 20,000
  cases), required after any change to the decoder.
- **The size limit applies in either orientation.** It is now a long side up to 1920
  and a short side up to 1080, with neither under 16. Read as width ≤ 1920 and
  height ≤ 1080, the limit rejected every portrait stream, which the spec requires to
  work. The pixel bound is unchanged, only turned on its side. The controller's format
  choice and the host's request check use the same rule.
- **The host decodes on a thread of its own,** behind a two-unit queue. When that
  queue is full the unit is dropped, everything up to the next key frame is dropped
  too, and the controller is asked for a key frame. A unit that fails to decode leads
  to the same.
