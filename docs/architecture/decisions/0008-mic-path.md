# 0008. Mic and sound paths: fixed voice-call capture, low-latency buffer, no mic fallback

- **Status:** Accepted, 2026-10-24 (review findings A-2, A-3, A-4, A-6; PR #16)
- **Original design:** Departs from the spec, which reused the voice-call capture and
  `AudioHandler` as they are and treated system sound as a build flag. Follows the
  engine-hook rule for each fix.

## Context

- `start_voice_call()` relays audio on a thread that spins on `try_recv()`, and keeps
  the first input device ever set; the device is a process-wide global.
- `AudioHandler` buffers at least 600 ms (3 s ring, shrinks every ~12 s) and sleeps in
  the Core Audio output callback.
- With `screencapturekit` on, `get_device()` still falls back to the host's default
  input device when ScreenCaptureKit is unavailable.
- Without headphones, the host app's echo canceller can't remove the controller's
  speaker-to-mic echo: the speaker is on another machine, 100–300 ms away.

## Decision

- Reuse voice-call capture with three fixes: a blocking receive, `set_if_present = true`
  with a restart on device change, and a per-session device.
- The virtual-mic and speaker paths get their own jitter buffer: 40–100 ms target,
  drop oldest on overflow, silence on underrun, no sleeping in the callback.
- On a Mac host, system-sound capture never falls back to an input device; it reports
  itself unavailable instead. This changes the server's loopback only.
- Capture the controller mic with Apple voice processing; if that isn't enough, v1
  asks for headphones.

## Consequences

- Mic latency gets a target (under 150 ms on a LAN) instead of "measured".
- Several small, separate hooks in engine audio code, each listed in HOOKS.md.
