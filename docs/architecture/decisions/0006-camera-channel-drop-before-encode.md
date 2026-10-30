# 0006. Own bounded channel for camera frames; drop before encoding

- **Status:** Accepted, 2026-10-24 (review finding V-5; PR #16)
- **Original design:** Departs from the spec, which dropped frames once 150 ms waited in
  "the session's sender". Follows the engine-hook rule: one marked hook in `io_loop.rs`,
  listed in HOOKS.md.

## Context

The session sender in `src/client/io_loop.rs` is an unbounded `mpsc` channel shared
with mouse and keyboard events, with no way to see its depth or age. Camera frames
pushed there would make input wait behind video. Dropping an already-encoded P-frame
smears the picture until the next key frame.

## Decision

- Drop before encoding: capture hands frames to the encoder through a one-frame slot.
- Camera frames get their own bounded channel (2–4 frames) into the io loop, polled
  after input in a biased `select!`.
- Track bytes and age in flight; past 150 ms, skip capture frames until it drains. If
  an encoded frame must still be dropped, force a key frame on the next encode.

## Consequences

- Input stays responsive whatever the camera does.
- One hook in `io_loop.rs`, the only engine file outside new ones that the sender
  touches.

## Implementation (2026-10-27)

`src/client/device_forward.rs`, hooked into `io_loop.rs` and `client.rs` (`HOOKS.md` E6).
The capture side, with its one-frame slot and skipping, is in
`src/platform/macos_camera_capture.mm` (decision 0004).

- **The queue** holds 3 encoded frames. The encoder's thread fills it with `try_send`.
  The io loop takes frames in a `select!` branch of their own and sends them as
  `CameraFrame`.
- **Input first, without biasing upstream's `select!`.** A biased `select!` would
  poll the host's video branch first every time and could starve the others. Instead,
  the camera branch handles any input the UI has already queued before it sends a
  frame. Input then never waits behind camera frames waiting in the queue. It can
  still wait behind one camera frame being written to the network, as it would behind
  any other message.
- **Backlog:** when a frame has waited over 150 ms and another is behind it, capture
  frames are skipped before encoding until the queue drains.
- **A full queue** drops the frame after encoding. Every later frame is then dropped
  too until the next key frame, because those frames reference the dropped one. That
  key frame is requested at the next chance. This extends the decision, which only
  asked for the key frame.
- **What else it enforces** (not in the spec):
  - The camera waits up to 10 s for the host's answer, then stops and tells the host.
    A 1.0.x host never answers; the Devices menu should not ask one in the first place.
  - A host's key-frame requests are honoured at most once per 500 ms. The spec puts
    that limit on the host; here it is enforced on the controller too.
  - The host's bitrate is kept within 100–2000 kbit/s.
- **Not yet:** the microphone (Phase 2) is refused with a log line. The Devices menu
  and its FFI call send `Data::DeviceForward`; nothing does yet.
