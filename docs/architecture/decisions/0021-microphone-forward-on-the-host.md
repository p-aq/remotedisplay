# 0021. The host plays a microphone forward into Remote Display Microphone through its own jitter buffer

- **Status:** Accepted, 2026-10-28 (issue #3)
- **Original design:** Follows the spec's Host side › Microphone and decisions 0013 and
  0015: the harness's `mic_sink.mm` moves into the engine, and the jitter buffer goes in
  its render callback. Departs from "AudioHandler::start_audio … needs a target-device
  parameter": the microphone doesn't go through `AudioHandler` at all. Settles two things
  the spec leaves open: the microphone's status, and a microphone forward during a voice
  call.

## Context

- **Where the audio goes.** Decision 0013 feeds Remote Display Microphone through the
  driver's hidden, output-only twin, which `remotedisplayd` opens by UID. Hidden devices
  aren't in Core Audio's device list. `AudioHandler` plays through cpal, which only opens
  devices from that list, so a target-device parameter couldn't reach the feeder.
- **Buffering.** The spec already asks for a separate buffer: `AudioHandler`'s ring holds
  3 s, shrinks only every 12 s or so and never below 600 ms, and sleeps inside the output
  callback. With its own buffer and its own output, all that is left of `AudioHandler`
  to reuse is decoding: the Opus decoder and the engine's `audio_resample` and
  `audio_rechannel`.
- **Status.** The microphone has no approval step: the driver is installed with an admin
  password, and then it's there. `not-approved` never applies.
- **A voice call at the same time.** The spec says the host routes a forward's audio "to
  the virtual mic instead of its speakers", but not what happens if the same controller
  also has a voice call running. Both carry the controller's microphone.

## Decision

- **Status.** `rd_mic_sink` and the microphone's `DeviceStatus` are `ready` when the
  driver's hidden feeder exists (found by its UID, asked at most once a second and only
  while the owner's switch is on), `not-installed` when it doesn't, and `not-allowed`
  with the switch off.
- **Requests,** as for the camera:
  - the owner's switch and the driver must be there;
  - one controller at a time across connections, others get `busy`;
  - the switch going off or the driver going away ends the forward, with
    `DeviceForwardResponse{accepted: false}` and the reason;
  - the connection closing ends it.
  The request's format fields are for the camera. The microphone's format arrives as an
  `AudioFormat`, as for a voice call. A new request from the same controller (another
  microphone picked) starts afresh.
- **Audio.** Decision 0007's gate lets a controller's audio through during an accepted
  microphone forward as well as a voice call. While a forward is accepted, that
  connection's `AudioFormat` and `AudioFrame`s go to Remote Display Microphone and not to
  the speakers, even during a voice call. Otherwise the host's speakers would play the
  controller's voice into the same room as the call that is hearing it.
- **Playback.**
  - `src/platform/macos_mic_sink.mm` is Option A of the harness's `mic_sink.mm`, moved
    unchanged in behaviour. Option B stays in the harness as the documented fallback.
  - The controller's Opus is decoded on a thread of its own (`mic-forward`) and converted
    to the feeder's rate and channels. A queue of 50 frames leads to it; frames beyond
    that are dropped.
  - Decoded audio goes into a jitter buffer that the render callback reads on Core
    Audio's real-time thread. It starts playing once 40 ms are buffered, drops the oldest
    audio back to 40 ms when more than 100 ms are waiting, and on running dry plays
    silence until 40 ms are buffered again.
  - The buffer is `ringbuf`'s single-producer, single-consumer ring, already an engine
    dependency, so the callback takes no lock, allocates nothing and never sleeps. When
    the ring itself is full (the device stopped reading), the newest audio is dropped.
  - Ending a forward stops the feeder; the driver then gives readers silence.

## Consequences

- No change to `AudioHandler`: the controller's playback of the host's sound keeps
  upstream's buffering. The spec's separate buffer for that "speaker path" is still to
  do.
- The server app doesn't show the microphone yet: no badge, no *Microphone from …* line.
  `remotedisplay-forwarding.json` already names the sender, as `"microphone"`. The app
  shows it with the driver's packaging and Setup's Microphone row.
- The controller doesn't send its microphone yet. It needs voice-processed capture
  started by `DeviceForwardResponse` and the Devices menu's Microphone row (issue #3).
- Unit-tested with a fake feed and on the buffer itself. Two `#[ignore]`d tests use the
  real driver (2026-10-29):
  - **`make engine`** in `docs/tests/virtual-mic/harness` plays a controller's Opus
    bursts through the real path while the Phase 0 probe records. Three runs passed: the
    median delay from a frame reaching the host to its sound in the device was 48.6,
    54.0 and 55.2 ms. Every sample sent was played; nothing was dropped and there were no
    underruns until the frames stopped.
  - **`make own-mic`** in `docs/tests/system-sound/harness` fails: the host's sound
    carries the microphone back to the controller (100 of 100 tone windows). See the
    next point.
- **Host sound and the microphone come from one process.** cpal's ScreenCaptureKit
  capture sets `excludesCurrentProcessAudio` to false, and `remotedisplayd` both
  captures the host's sound and plays the microphone. ScreenCaptureKit captures by
  process, not by device: the tone went to the hidden feeder, not the speakers, and
  still came back. A controller with *Play the Mac's sound here* on would hear its own
  voice about 50 ms late.
  - With a scratch copy of cpal that sets it to true, `make own-mic` passed (silence, 0
    tone windows), and `make hears` still passed (100 of 100: other processes' sound
    still goes out).
  - The engine's cpal is a git dependency outside the snapshot, so carrying that change
    needs its own decision. The microphone forward isn't usable until it lands.
