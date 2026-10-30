# Controller microphone — Phase 2 (2026-10-29)

Checks that a controller Mac captures a real microphone and sends it as a microphone
forward should (issue #3, [spec](../../specs/camera-audio-forwarding.md) Controller side ›
Microphone capture; decisions
[0023](../../architecture/decisions/0023-controller-microphone-capture.md),
[0024](../../architecture/decisions/0024-devices-menu-microphone-row.md),
[0025](../../architecture/decisions/0025-cpal-buffer-range-from-the-device.md) and
[0026](../../architecture/decisions/0026-echo-headphones-not-voice-processing.md)). Also
measures Apple's voice processing against echo.

**Status:** capture and the sender pass on this Mac with a USB webcam's microphone: 100 frames a second of 48 kHz mono Opus, a tone through the speakers heard 60 dB over the room, nothing before the host accepts or after it stops. The microphone list answers in under 0.1 s before macOS has been asked. A Bluetooth headset's 16 kHz input carries a voice at 100 frames a second too. Turning the headset off ends the forward, and the host and the menu are told. The first run found three bugs, now fixed: a 100 Hz buzz on 16 kHz inputs, a list that waited on the microphone prompt (and output-only speakers with no configs), and a default input that went away unnoticed. Apple's voice processing didn't start here in any of four ways, so echo stays the headphones hint (decision 0026).

## What's here

| Piece | What it is |
|---|---|
| `engine/rustdesk/src/client/device_forward/mic.rs` | The capture (`HOOKS.md` E12). Its `capture` module holds four `#[ignore]`d tests, run from the bundle: `lists_microphones_but_not_ours`, `nothing_without_microphone_access`, `asks_for_microphone_access`, `sends_the_microphone_as_opus`. `RD_MIC` names the input and `RD_SPEAKER` the output the tone plays through. Its unit tests run with every `cargo test`, including `resampling_runs_on_across_frames` and, on a Mac, `cpal_reads_each_device_without_opening_it` |
| `engine/rustdesk/src/client/device_forward.rs` | The sender. Its `capture` module adds `forwards_the_microphone`, `tells_the_host_when_the_microphone_is_unplugged` and `the_menu_lists_the_macs_microphones`, beside the camera's |
| `engine/rustdesk/libs/cpal/src/host/coreaudio/macos/mod.rs` | The vendored cpal, which reads a device's buffer sizes from the device (`HOOKS.md` E13, decision 0025) |
| `harness/Makefile` | Builds the engine's test binary and wraps it as `rd-mic-capture-probe.app`, so microphone access is asked for and granted to that bundle and not to the terminal. Builds `rd-voice-probe.app` and the speech it plays (`say`). Targets `list`, `nothing`, `ask`, `sends`, `forwards`, `unplug`, `voice`, `revoke`, `clean`; `MIC=` and `SPEAKER=` pass through `open --env`, which leaves the signed bundle as it is |
| `harness/voice_probe.mm` | `rd-voice-probe`: AVAudioEngine's input node with voice processing, the devices picked four ways (`--pick after,before,input,none`). For each way that starts, it plays speech through its own output, another output and another process, and records the processed input and the same input unprocessed side by side. It also reports which devices run, and how much other audio is lowered |
| `harness/gate.sh` | The tests in order, with the prompts to answer; ends by revoking both grants and deleting the bundles |
| `harness/probe-Info.plist`, `harness/voice-Info.plist` | The bundles' identities, `app.remotedisplay.spike.mic-capture-probe` and `app.remotedisplay.spike.voice-probe`: no Dock icon, and the microphone usage text macOS requires |

## What was tested and the result

Run 2026-10-29 on a Mac mini (Apple M4, macOS 15.7.7, Xcode 26.3) from an agent's shell,
with a person answering the prompts. Inputs: a Jabra Bluetooth headset (the default
input and output, 16 kHz in) and a Microsoft LifeCam HD-3000's microphone (USB, 48 kHz).
Output for the tone: the Mac mini Speakers, at volume 0.44.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | Build | `make` | Builds; no warnings from our files | **PASS** |
| 2 | Resampling | `cargo test --lib resampling_runs_on_across_frames` | A 440 Hz tone at 16, 24 and 44.1 kHz, delivered in uneven pieces, is within 0.01 of the tone at 48 kHz | **PASS** after the fix. Before it, 16 kHz was off by 0.19 on a 0.3 tone ([findings](#runtime-findings)) |
| 3 | cpal reads devices | `cargo test --lib cpal_reads_each_device_without_opening_it` | Every device has its configs, and a default config for each direction it has | **PASS** with decision 0025; without it, "Mac mini Speakers: no configs" |
| 4 | Microphones listed | `make list`, before access is asked | At least one, not Remote Display Microphone, within a second | **PASS**: 56–73 ms, five inputs (the headset, the LifeCam, NDI Audio, Microsoft Teams Audio, ZoomAudioDevice). The first run waited on the microphone prompt until it was stopped. Once allowed, the list matched cpal's own input list |
| 5 | Access refused | `make revoke`, then `make nothing` | `start` fails at once with "microphone access isn't allowed"; nothing is sent | **PASS**: refused in 0.15–0.2 ms |
| 6 | Prompt | `make ask` | macOS asks; Allow grants access | **PASS**: answered in 23 s, and again after each rebuild |
| 7 | Capture, USB | `make sends MIC="Microsoft® LifeCam HD-3000" SPEAKER="Mac mini Speakers"` | 95–105 frames a second, each 10 ms of 48 kHz mono Opus; the room isn't digital silence; a second of 1 kHz tone is at least 10 dB over the room at 1 kHz; at most one frame after the capture is dropped | **PASS**: the first frame 240 ms after starting, 100.1 a second; room −44.6 dBFS RMS; 1 kHz at −100.2 dBFS before the tone and −39.9 dBFS during it; 0 frames after stopping |
| 8 | Capture, Bluetooth | `make sends MIC="Paolo-Jabra-headset" SPEAKER="Mac mini Speakers"`, silent five times, then three times while a person counts out loud | As test 7; and a voice is heard over the silent runs | The path works, but the test's own checks fail. 99.8–100.0 frames a second, at most one after stopping. The first second after opening is digital zeros ([findings](#runtime-findings)). Silent, the headset gave −95 dBFS, and the tone only −94 dBFS. Counting, it gave −64 to −71 dBFS: the voice comes through, 25–30 dB over silence, though quietly for a headset mic. The tone check doesn't suit a noise-cancelling headset |
| 9 | The sender | `make forwards`, with the default input and with `MIC="Microsoft® LifeCam HD-3000"` | The request names the input; nothing before the host accepts; `AudioFormat` 48000 Hz, 1 channel first, then only `AudioFrame`s, about 100 a second; nothing after the host stops it | **PASS** both ways: 300 `AudioFrame`s in 3 s, 0 after `not-allowed`. The request named the LifeCam when picked, and "" for the default |
| 10 | Unplugging | `make unplug MIC="Paolo-Jabra-headset"`, the headset powered off when the Mac says so | The host is told `on: false`, no frame follows, the menu hears `microphone-lost` | **PASS**: 640 `AudioFrame`s, then `on: false` about 4 s after the cue, 0 after, and the menu heard `microphone-lost`. The first tries had no spoken cue: the headset was muted (macOS logged a mic gain of 0) or turned off before the test started. Hence the cue ([findings](#runtime-findings)) |
| 11 | Voice processing | `make voice MIC="Microsoft® LifeCam HD-3000" SPEAKER="Mac mini Speakers"` | The engine starts with voice processing at least one way, recording the picked input | **FAIL** all four ways: the engine didn't start (-10875), the system's defaults included. Each time, turning voice processing on blocked for minutes. Decision 0026 |
| 12 | Nothing left behind | `make clean` | Both grants reset, both bundles unregistered and deleted, the logs deleted, no `~/Library/Preferences/RemoteDisplay` | **PASS**, after both rounds: also no Launch Services entry and no probe process left, and the home folder's usual build locations unchanged |

## Runtime findings

- **A 16 kHz input buzzed at 100 Hz.** Each 10 ms was resampled on its own. The last
  samples at 48 kHz lie between that 10 ms and the next, and with nothing after them
  they fell toward zero. Bluetooth headsets on a call run at 16 kHz, so this is the
  common case. The resampler now gets the next 10 ms's first sample too
  (`next_frame()` in `mic.rs`).
- **cpal opened each device for input to read its buffer sizes** (decision 0025).
  Listing the inputs waited in macOS's privacy check until someone answered the prompt.
  The Devices menu reads the list synchronously, so it would have frozen. Output-only
  devices, the Mac mini Speakers among them, had no configs at all. Found when the
  first `make list` waited until it was stopped, and the tone found no "Mac mini
  Speakers" among cpal's outputs.
- **cpal tells a stream its device went away only if it isn't the default**
  (`if !self.is_default` before `add_disconnect_listener`). The forward opened the
  default input through `default_input_device()`, so a default that went away would
  have gone quiet with no one told. The default is now looked up by name among the
  inputs.
- **A Bluetooth headset is two devices with one name**: an input at 16 kHz and an
  output at 44.1 kHz. Opening its input sends digital zeros for about a second while the
  call link comes up; a second capture right after starts with sound. The host hears
  silence for that second, which is harmless.
- **Muting a headset isn't losing it.** Its mute button sends macOS a mic gain of 0, then
  silence. The device stays, so the forward stays on, sending silence, which is right.
  Powered off, the device goes. macOS then moves the default input and output to the
  next devices, and back when the headset reconnects.
- **A person needs a cue to unplug at the right moment.** Working remotely, a typed
  "unplug it now" arrives late. Twice the headset was off before the test started, and
  once not within its minute. `make unplug` now says "Unplug the microphone now" through
  the default output once the forward is sending, so a headset hears it.
- **Voice processing reported 16 kHz, 2 channels** in all four ways: the headset's rate,
  whatever was picked. That suggests it took its formats from the default devices
  before the picked ones applied.
- **The probe's unprocessed baseline couldn't see the speech** in a −35 dBFS room
  (RMS over the room). Measuring an echo below the room's level needs a correlation
  with the speech played. That doesn't matter while voice processing doesn't start.
- From the camera harness, still true here: an ad-hoc signed probe loses its grant on
  every rebuild, so answer the prompt again after each `make`. A prompt left unanswered
  stays on screen, and answering it later grants the same build. tccd logs
  `AUTHREQ_PROMPTING … kTCCServiceMicrophone` when it shows one.

## Not yet tested

- Unplugging the default input without naming it. The default is looked up by name, the
  same way a named input is (test 9 passed with the default), but only a named input was
  unplugged.
- A USB microphone unplugged mid-forward.
- A built-in microphone, and voice processing on a Mac whose defaults are its own
  microphone and speakers (decision 0026).
- The capture inside a real session, with a host playing it into Remote Display
  Microphone (the host side was measured in `docs/tests/virtual-mic/`). That needs a
  second Mac.

## Re-running

```sh
source <toolchains>/env.sh
cd docs/tests/mic-capture/harness
make && MIC="Microsoft® LifeCam HD-3000" SPEAKER="Mac mini Speakers" ./gate.sh
```

`make` reads `MIC` and `SPEAKER` from the environment, so they reach every target.
Pick a microphone that hears the speaker, not a headset's.
