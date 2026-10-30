# System sound — Phase 3 (2026-10-26)

Checks that a Mac host sends its system sound, captured by ScreenCaptureKit, and never
its microphone (issue #4, [spec](../../specs/camera-audio-forwarding.md) Host side ›
Speakers, [decision 0008](../../architecture/decisions/0008-mic-path.md)).

**Status:** the engine side passes the gate on this Mac. The frames a controller would
receive carry a tone played on the host, and with Screen Recording refused nothing is
sent ([results](#what-was-tested-and-the-result)). Still to do: listening from a real
controller, the *Play the Mac's sound here* switch, and a call running on the host
([not yet tested](#not-yet-tested)).

**Found in Phase 2 (2026-10-29):** the host's sound carries a controller's forwarded
microphone back to it. `remotedisplayd` plays the microphone, and cpal's ScreenCaptureKit
capture includes the process's own audio. Turning on `excludesCurrentProcessAudio`
fixes it and keeps the host's sound ([results](#own-microphone-phase-2)).

## What's here

| Piece | What it is |
|---|---|
| `engine/rustdesk/src/server/audio_service/host_sound.rs` | `source()`, where host sound comes from, with its unit tests (`HOOKS.md` E1). Its `capture` module holds three `#[ignore]`d tests. Each subscribes to the engine's audio service the way a controller's connection does, plays a 2 s, 1 kHz tone through the default output with `afplay` and decodes the Opus frames it receives. `controller_hears_system_sound` counts the 20 ms windows that are mostly the tone (Goertzel power against the window's energy); `nothing_without_screen_recording` requires zero frames. `controller_never_hears_its_own_microphone` plays the tone into Remote Display Microphone instead, through the engine's own microphone path (decision 0021); it needs `../virtual-mic`'s driver installed and passes when none of it comes back |
| `harness/Makefile` | Builds the engine's test binary with `--features hwcodec,screencapturekit` (full Xcode, see `tools/README.md`) and wraps it as `rd-sound-probe.app`, so Screen Recording is granted to that bundle and not to the terminal. Targets `hears`, `nothing`, `own-mic`, `revoke`, `clean` |
| `harness/gate.sh` | The tests in order, with the prompts to answer; ends by revoking the grant and deleting the bundle |
| `harness/probe-Info.plist` | The bundle's identity, `app.remotedisplay.spike.sound-probe`, with no Dock icon |

The tests sit in the engine because the audio service is crate-private; the harness
only builds and launches them.

## What was tested and the result

Run 2026-10-26 on a Mac mini (Apple M4, macOS 15.7.7, Xcode 26.3), from the Claude app's
Terminal panel and an agent's shell, with a person turning Screen Recording on. The
default input is a USB webcam microphone (Microsoft LifeCam HD-3000); the Mac mini has
no built-in one. Output volume 44%.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | Build | `make` | The engine's lib tests build with `screencapturekit`; no warnings from our files | **PASS**: 83 s, the 5 upstream warnings only. The server binary links `ScreenCaptureKit.framework` |
| 2 | Screen Recording refused | `make revoke`, then `make nothing` | No `AudioFormat` and no `AudioFrame` reach the subscriber | **PASS**: format none, 0 frames in 4 s |
| 3 | Screen Recording allowed | Turn rd-sound-probe on in System Settings, then `make hears` | At least 50 of the 100 tone windows | **PASS**: 48 kHz stereo, 374 frames, peak 0.338 for 0.33 sent, **100/100**. The run before the grant failed with 0 frames, as expected |
| 4 | Output muted | `gate.sh` step 3 | Recorded, not required | The tone still arrives: 380 frames, peak 0.344, 100/100 |
| 5 | Nothing left behind | `make clean` | Grant reset, bundle unregistered and deleted, no `~/Library/Preferences/RemoteDisplay` or `~/Library/Logs/RemoteDisplay` | **PASS**; the probe's own `HOME` stayed empty |

Against the gate, *the controller hears a test tone*: the frames a controller decodes
carry it, in every window. Listening on a real controller is still to do. *The host's
microphone is never sent*: with Screen Recording refused the service sends nothing at
all, and `source()`'s unit tests cover the fallbacks the guard refuses (a missing named
input, ScreenCaptureKit unavailable).

### Own microphone (Phase 2)

Run 2026-10-29 with `../virtual-mic`'s driver installed and rd-sound-probe allowed. The
`make own-mic` test plays 2 s of a controller's 1 kHz tone into Remote Display
Microphone from the test's own process, as `remotedisplayd` does, while subscribed to
host sound:

| Build | `make own-mic` | `make hears` |
|---|---|---|
| cpal as the engine has it (`excludesCurrentProcessAudio` false) | **FAIL**: 100 of 100 tone windows came back, peak 0.311 for 0.3 sent | — |
| cpal with `excludesCurrentProcessAudio` true (a scratch copy, this test only) | **PASS**: 380 frames of silence, peak 0.000, 0 tone windows | **PASS**: 100 of 100, peak 0.344; `afplay` is another process |

- **ScreenCaptureKit captures by process, not by device.** The tone went to the driver's
  hidden feeder, not the speakers, and still came back. So a controller with *Play the
  Mac's sound here* on would hear its own voice about 50 ms late.
- **Rebuilding the bundle cancels the grant.** The ad-hoc signature changes with the
  binary, and turning rd-sound-probe off and on didn't help: `make revoke`, one refused
  run, then turning it on again did.

## Runtime findings

- **Capture happens before the volume control and mute.** The peak was 0.338 at 44%
  volume and 0.344 with the output muted. A muted host still sends its sound at full
  level, which suits a headless host. It also means muting the host never stops the
  sound going out: only the controller's switch (`disable_audio`) does.
- **A refused grant fails before any format is sent.** The service's `play()` fails
  inside ScreenCaptureKit and the service retries each second; the subscriber gets nothing.
  On macOS 13+ the fork's `is_screen_capture_kit_available()` is always true, so this
  is the path a host without Screen Recording takes. The guard matters for a missing
  named input and older systems.
- **ScreenCaptureKit delivers 48 kHz stereo**, so host sound goes out as 48 kHz stereo
  Opus in 10 ms frames, about 100 a second.
- **The grant needs a fresh process.** After rd-sound-probe was refused once, it
  appeared in System Settings › Screen & System Audio Recording; turning it on worked
  from the next launch.
- **`open --stdout` can't write to an external drive.** It fails with -10810
  (`_LSOpenURLsWithCompletionHandler`), so the harness logs to the system temp folder.
  `open -W` also can't wait for a process that exits at once, so `run` waits for
  libtest's last line.
- **`tccutil reset` needs the bundle registered** with Launch Services (-10814
  otherwise). `revoke` registers it first and `clean` unregisters it.
- **Launched with no arguments, the bundle would run all of the engine's unit tests**,
  for example from System Settings' *Quit & Reopen*. Its `LSEnvironment` keeps `HOME`
  inside `build/` for that case, and `gate.sh` asks for *Later*.

## Not yet tested

- Listening on a real controller. It decodes the same frames, but needs a second
  machine with the client.
- The *Play the Mac's sound here* switch and its "unavailable" status: they need the
  Devices menu and `DeviceStatus` (Phase 1, [decision 0012](../../architecture/decisions/0012-devices-menu-and-device-status.md)).
  Until then the engine's existing Mute toggle (Input › Session) controls host sound.
- A call running on the host (echo, ducking), the spec's open question.
- `make own-mic` passes only once the engine's cpal excludes `remotedisplayd`'s own
  audio; until then it fails as above.
- The release build itself (`release/release-mac.sh` on the release Mac, Xcode 27).

## Re-running

From this folder, in a shell with the toolchain and Xcode (`tools/README.md`):

```sh
source <toolchains>/env.sh
cd harness
make
./gate.sh     # tone through the speakers three times; keep other sound off
make own-mic  # with ../virtual-mic's driver installed and the grant on
```

`gate.sh` asks you to deny the first prompt and to turn rd-sound-probe on for test 3.
If Return doesn't reach it, run `make hears` once the grant is on, then `make clean`.
