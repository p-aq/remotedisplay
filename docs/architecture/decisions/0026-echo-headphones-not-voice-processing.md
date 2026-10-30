# 0026. Echo on the controller: the headphones hint, not Apple's voice processing

- **Status:** Accepted, 2026-10-29 (issue #3)
- **Original design:** Departs from the spec's first answer to echo, "capture the
  controller mic with Apple's voice processing (AVAudioEngine's input node)", and takes
  its second: "v1 asks for headphones, with a hint in the Devices menu". Settles what
  decisions 0023 and 0024 left to measure.

## Context

- **The echo.** Without headphones, the host's sound played on the controller reaches
  its microphone and goes back into the host's call (decision 0023).
- **What was measured** (2026-10-29, `docs/tests/mic-capture/`, `rd-voice-probe`). This
  was a Mac mini (M4, macOS 15.7.7) with a Bluetooth headset as the default input and
  output, a USB webcam's microphone and the built-in speakers. Voice processing was
  tried four ways:
  - its devices set on its unit after turning it on;
  - set on the engine's plain units before;
  - only the input set;
  - the system's defaults left as they were.

  The unit took the picked devices and read them back, but **the engine didn't start in
  any of the four** (`kAudioUnitErr_FailedInitialization`, -10875), the defaults
  included. Its input reported 16 kHz, 2 channels each time: the headset's rate,
  whatever was picked. Each time, **turning voice processing on blocked for minutes**
  in Apple's AudioDSP before returning.
- **The design captures the input the menu picked**, per forward (decision 0023).
  Reports from other projects say voice processing records from the default input
  whatever is picked, and fails with the input and output on different devices. Here
  it didn't run at all.

## Decision

- **No voice processing.** The capture stays as decision 0023 built it: cpal, the
  picked input, no processing.
- **The headphones hint is v1's answer to echo.** It stays as decision 0024 built it:
  while the microphone and *Play the Mac's sound here* are both on, the row says "Use
  headphones, or the call hears its own echo". No longer "until voice processing is
  measured".

## Consequences

- Without headphones, the host's call can hear itself back. The hint says so, and
  turning *Play the Mac's sound here* off also stops it.
- **Not tried:** a Mac whose defaults are its own built-in microphone and speakers,
  such as a MacBook, where voice processing may start. Even there it would follow the
  system's defaults, not the menu's pick.
- **If the hint isn't enough**, a software echo canceller in the controller is the way:
  for example WebRTC's audio processing, with the host's sound as its reference. The
  client plays that sound itself (`src/client.rs`), so it has the exact signal to
  cancel, whatever the devices. Not built.
- `rd-voice-probe` stays in the harness to measure again on another Mac.
