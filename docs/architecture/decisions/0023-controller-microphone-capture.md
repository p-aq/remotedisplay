# 0023. The controller captures its microphone per forward, not through the voice call's audio service

- **Status:** Accepted, 2026-10-29 (issue #3)
- **Original design:** Follows the spec's sending rules and the camera's sender (decision
  0006 and 0020): ask, send only once accepted, stop on switch-off, refusal, no answer, a
  lost device or the session ending. Departs from "reuse `start_voice_call()` … with three
  fixes": the microphone gets its own capture. That capture meets the three fixes' aims
  without changing the voice call. Leaves the spec's Apple voice processing for a
  measured step (see Consequences).

## Context

- **The voice call's capture is shared.** `start_voice_call()` subscribes to the client's
  own audio service (`CLIENT_SERVER`), which captures one input for the whole process.
  The device is a global (`VOICE_CALL_INPUT_DEVICE`), and the service, its zero gate and
  its restart flag are statics.
- **The spec's three fixes:**
  - a blocking receive instead of the relay thread's `try_recv` spin;
  - `set_if_present = true`, so a later pick of the device takes effect;
  - a per-session device.
  The first two are small changes to upstream code. The third isn't: the device belongs
  to one service instance per process. Two sessions forwarding different microphones, or
  a forward next to a voice call, would fight over it.
- **Voice processing.** The spec asks for Apple's voice processing (AVAudioEngine's input
  node), so the controller's own speakers don't echo into the host's call. cpal, which
  the audio service captures with, can't turn it on. Reports from other projects say
  that on macOS it:
  - may record from the default input whatever device is picked;
  - fails when input and output are on different devices;
  - may not cancel audio that other apps play. That matters because the host's sound
    plays through the engine's own output.
  It has to be measured with a real microphone and speakers before the design leans on
  it, and the build Mac has no microphone attached now.

## Decision

- **Each forward opens its own capture** of the input the menu asked for
  (`src/client/device_forward/mic.rs`). The device belongs to that session. The voice
  call, its global and its relay thread are unchanged.
- **Capture through cpal, encoded the way a voice call is:** Opus in low-delay mode, 10 ms
  frames. The device's samples are mixed to mono and resampled to 48 kHz, so the
  `AudioFormat` is always 48 kHz mono and known before the device opens. cpal's stream
  can't leave the thread that made it, so capture runs on a thread of its own and stops
  when the forward drops it.
- **macOS access first.** Opening an input before macOS has answered blocks in its
  privacy check (Phase 0). So the capture fails at once without access, and the Devices
  menu asks first, as it does for the camera. `macos_mic_capture.mm` reads and requests
  the access. The menu's existing `main_get_capture_permission` and
  `main_request_capture_permission` now answer for the microphone too.
- **The forward follows the camera's rules.**
  - It sends `DeviceForwardRequest{MICROPHONE}` naming the input, and waits up to 10 s
    for the answer.
  - Once accepted, the `AudioFormat` goes first, then the `AudioFrame`s. They reach the io
    loop through a queue of their own, half a second long. Beyond that the newest are
    dropped.
  - The forward ends on switch-off, refusal, no answer, the session ending, or the input
    going away, which the host is told about.
- **The menu's state** gains `"microphone"`, beside `"camera"`, with the same fields.
  The reasons are the host's, `no-answer`, `microphone-failed` (it didn't start) and
  `microphone-lost`.

## Consequences

- No change to upstream's voice call. The spec's three fixes stay undone there, because
  the microphone forward no longer goes through it.
- A microphone forward next to a voice call on the same session would send two audio
  streams, and the host plays both into Remote Display Microphone (decision 0021). The
  Devices menu keeps the microphone off during a voice call
  ([decision 0024](0024-devices-menu-microphone-row.md)).
- **Echo isn't handled yet.** Without headphones, the host's sound played on the
  controller reaches its microphone and goes back into the host's call. Next, with a
  microphone attached:
  - measure Apple's voice processing (which device it uses, whether it cancels the
    engine's playback);
  - then decide between it and the spec's fallback, a headphones hint when both
    Microphone and *Play the Mac's sound here* are on.
- Unit-tested with a fake microphone (the forward's rules) and on the encoder (mono and
  stereo, 48 and 44.1 kHz, levels kept). A real microphone hasn't been captured yet.
- Windows can use the same capture (cpal). Linux can't, because the engine doesn't build
  cpal there.
