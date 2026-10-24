# 0003. Camera rides the session as its own `CameraFrame` message

- **Status:** Accepted, 2026-10-23
- **Original design:** Follows the spec.

## Context

The engine already carries encoded video in `VideoFrame`, but `VideoFrame.display`
means one of the host's displays, and all existing code assumes video flows from host
to controller.

## Decision

Controller-to-host camera video travels in a new `CameraFrame` message that wraps a
`VideoFrame` (reusing the `EncodedVideoFrames` payload) plus a capture timestamp.
`CameraControl` carries key frame requests and bitrate the other way. Media stays
inside the existing encrypted session: no new port, listener or relay.

## Consequences

- Older peers and upstream code never mistake camera video for a screen.
- The codec payload is shared with screen video, so Phase 4 controllers can reuse
  existing encoders.
