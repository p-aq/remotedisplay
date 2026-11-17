# 0007. Host accepts controller audio only during an accepted forward

- **Status:** Accepted, 2026-10-24 (review finding A-1; PR #16)
- **Original design:** Extends the spec's security model ("off by default; only the
  host owner can allow it") to audio that already flows today.

## Context

`src/server/connection.rs` plays any `Misc::AudioFormat` and `AudioFrame` a controller
sends whenever that controller's `disable_audio` option is off. Nothing checks that a
voice call was accepted. Turning off "Play the Mac's sound here" would silence the
controller's mic, and any connected controller can play sound on the host unasked.
Once that audio goes to a virtual mic, it becomes a way to put a voice into the host's
calls.

## Decision

The host accepts controller audio only while a `MICROPHONE` forward or a voice call is
active for that connection, independent of `disable_audio`. Anything else is dropped
and logged once.

## Consequences

- Closes an existing hole as well as the new one; listed as a security mitigation in
  the spec.
- Tests: mic still works with the host's sound off; unrequested audio is dropped.
- A hook in `connection.rs`, listed in `engine/SYNC.md`.

## Implementation (2026-10-26)

- `src/server/connection/audio_gate.rs`, called from the `AudioFormat` and `AudioFrame`
  handlers in `connection.rs` (`HOOKS.md` E2). The condition is the connection's
  `voice_calling`; Phase 2 adds the accepted `MICROPHONE` forward next to it.
- A controller sends its mic only after the host accepts its voice call
  (`VoiceCallResponse`), and the host sets `voice_calling` before reading the next
  message, so no legitimate audio is dropped.
- A Remote Display host never accepts voice calls: its headless CM (`core_main.rs`) has
  no one to accept them. So until Phase 2 it drops all controller audio. That is the hole closed, not a regression: nothing on the
  host asked for that audio.
- Drops are logged once per stretch of dropped audio, not per frame.
- Tested with unit tests. The end-to-end tests in the Consequences above need the mic
  forward and come with Phase 2.
