# 0029. The client plays received audio through the spec's jitter buffer, shared with the host's microphone path

- **Status:** Accepted, 2026-10-29 (issue #4)
- **Original design:** Follows the spec: "The virtual-mic and speaker paths use a separate
  jitter buffer: 40–100 ms target, drop the oldest audio on overflow, silence on underrun,
  no sleeping in the callback". Decision 0021 built it for the virtual mic; this applies it
  to the speaker path. Departs from upstream's `AudioHandler`, whose buffer goes.

## Context

- **The speaker path** is how a controller plays the audio its host sends: a Mac host's
  sound, or the far side of a voice call. It's upstream's `AudioHandler` in
  `src/client.rs`. Its ring held 3 s. It shrank only once every 12 s or so, never
  below 600 ms. Its output callback slept when the ring ran low, hoping more would
  arrive.
- **The virtual-mic path** already has the spec's buffer (decision 0021,
  `src/server/device_forward/mic.rs`). It's measured at 49–55 ms from a frame reaching the
  host to its sound in the device, with no glitches, and its reading side takes no lock
  and allocates nothing.

## Decision

- **One buffer, shared.** The jitter buffer moves, unchanged, from the host's microphone
  module to `src/client/jitter.rs`, with its tests. The client module builds on every
  platform. The host's microphone path uses it from there.
- **`AudioHandler` plays through it** on every platform but Linux, whose PulseAudio path
  stays as it was.
  - The decoded and converted audio goes into the buffer.
  - The output callback reads it into a buffer allocated beforehand.
  - The callback never sleeps.
  - Upstream's `AudioBuffer` and `AUDIO_BUFFER_MS` go.
- **What it did is logged** when playback ends: samples played, underruns and samples
  dropped. Crackles in a real session can then be told from a network that's too jittery
  for 40 ms.

## Consequences

- A controller hears its host's sound about 40–100 ms after it arrives, rather than
  600 ms or more.
- **Jitter above about 60 ms** (40 ms buffered plus a 10 ms frame each way) runs the
  buffer dry. The controller then plays silence until 40 ms are buffered again: a short
  gap where upstream's large buffer would have played on. That's the spec's trade for a
  call. It needs hearing on Tailscale and a busy network before release.
- Voice calls in both directions play through it too, since they use `AudioHandler`.
- Android and iOS clients change the same way and haven't been run.
- **Tested** (2026-10-29):
  - the buffer's four tests, moved;
  - the host's microphone tests, unchanged;
  - `plays_received_audio_without_running_dry` (`#[ignore]`, needs an output device),
    which plays 3 s of silent 48 kHz stereo Opus through `AudioHandler` and this Mac's
    default output in real time. Result: 284,032 samples played, 0 underruns, 0
    dropped.

  On RustDesk 1.5.1 the speaker path is decision 0030's. A live session with a second
  Mac played the host's sound cleanly ([live session](../../tests/live-session/README.md)).
