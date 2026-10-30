# 0028. The host says whether it can share its sound, and the Devices menu shows it

- **Status:** Accepted, 2026-10-29 (issue #4)
- **Original design:** Extends the spec for its Phase 3 test "revoke Screen Recording on
  the host, then turn the sound on: the switch says unavailable". The spec's protocol
  carries no status for sound: `DeviceStatus` and the login keys cover only the camera
  and the microphone. Follows how those keys work (decision 0012): a status string in
  `PeerInfo.platform_additions`, which the menu reads.

## Context

- **No fallback.** With `screencapturekit`, a Mac host's sound is ScreenCaptureKit's
  system audio and never falls back to an input device (decision 0008, `host_sound.rs`).
  When ScreenCaptureKit can't capture, the host sends nothing, which the system-sound
  harness's `make nothing` confirms.
- **The switch didn't know.** The Devices menu's *Play the Mac's sound here* showed off
  only when the host doesn't allow audio (`permissions['audio']`). A host without Screen
  Recording left the switch on and silent.
- **Screen Recording.** ScreenCaptureKit hears nothing without it. The engine needs it for
  the screen too, and the server app restarts the engine when it's granted, which ends the
  session.

## Decision

- **A login key, `rd_host_sound`**: "ready" or "unavailable". It's worked out the way the
  sound service picks its source (`host_sound::status`):
  - the owner's named input is "ready";
  - ScreenCaptureKit is "ready" only with Screen Recording;
  - otherwise "unavailable".

  Only a Mac host built with `screencapturekit` sends it, which is every release build.
- **The menu** (`soundReason` in `devices.dart`) shows the sound row off and disabled when
  the host doesn't allow audio, as before ("This computer doesn't share its sound"), or
  says "unavailable". The latter reads "This Mac can't share its sound until Screen
  Recording is on there". A host without the key, such as 1.0.x, changes nothing. The
  headphones hint counts the sound as off in both cases.
- **At login only, no `DeviceStatus` for sound.** Granting Screen Recording restarts the
  engine, so the next session hears the new status.

## Consequences

- Revoking Screen Recording during a session leaves the key at "ready" until the
  controller reconnects; the session's screen stops too.
- A named input that's missing still says "ready": the owner chose it, and capture fails
  as before.
- Unit-tested on both sides: `host_sound::status` in four cases, and `soundReason` in
  `client/test/devices_test.dart`. Not yet seen in a live session with Screen Recording
  revoked; that needs a second Mac.
