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
