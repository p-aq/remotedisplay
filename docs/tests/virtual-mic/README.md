# Virtual microphone — Phase 0 (2026-10-24)

Measures the two ways the host could publish "Remote Display Microphone", an input
device Zoom, Teams and Dictation can pick (issue #1, [spec](../../specs/camera-audio-forwarding.md)
Host side › Microphone, [decision 0013](../../architecture/decisions/0013-virtual-mic-input-only-driver.md)):

- **Option A**: a HAL driver, built from BlackHole, with a visible input-only device and a
  hidden output-only twin that `remotedisplayd` plays into.
- **Option B**: no driver. `remotedisplayd` plays into the default output, taps its own
  output with a Core Audio process tap, and publishes an aggregate device built on the tap.

**Status:** both options work. Each carries the test signal bit-exact into an
input-only "Remote Display Microphone" ([results](#phase-0-gate-tests)). Option A is
chosen ([decision 0013](../../architecture/decisions/0013-virtual-mic-input-only-driver.md)).
Still to run: Zoom and Teams picking the device (tests 4 and 8), and the reboot and
restart tests (5 and 10).

**Phase 2 (2026-10-29):** the engine's own path plays into Option A
([decision 0021](../../architecture/decisions/0021-microphone-forward-on-the-host.md)). A
controller's Opus arrives in Remote Display Microphone 49–55 ms after it reaches the
host, with no glitches ([results](#phase-2-the-engines-path)).

## What's here

| Harness | What it is | Becomes in Phase 2 |
|---|---|---|
| `harness/mic_sink.mm`, `.h` | Opens either option and plays whatever a render callback supplies, once per I/O cycle. `extern "C"` `MacMicSink…` functions, `-std=c++17`, no ARC, like `src/platform/macos.mm`. | Option A is now `engine/rustdesk/src/platform/macos_mic_sink.mm`; its callback reads the jitter buffer ([decision 0021](../../architecture/decisions/0021-microphone-forward-on-the-host.md)) |
| `harness/mic_feeder.mm` | `rd-mic-feeder --option a\|b`: a 50 ms, 1 kHz burst at every whole second of host time. Option B takes `--mute muted\|when-tapped\|unmuted` and `--with-output-subdevice`. | Replaced by decoded controller audio |
| `harness/mic_probe.mm` | `rd-mic-probe`: records from an input device like Zoom would, counts bursts and measures latency. Since bursts start on whole host seconds, each onset's time modulo one second is the latency, with no link between the two processes. Exits 0 on PASS. | A Phase 2 test |
| `harness/driver/Info.plist` + Makefile `driver` | Option A: BlackHole v0.7.2 (commit `561d934`) fetched at build time and configured, not modified, with its own build constants ([decision 0015](../../architecture/decisions/0015-virtual-mic-harness.md)). | `server-mac/AudioDriver/` |
| `harness/Makefile` | Builds everything with the Command Line Tools; `install-driver` / `uninstall-driver` need an admin and touch only our own bundle. `make engine` runs the engine's own path instead of the feeder (Phase 2). | Folded into `server-mac/Makefile` |
| `harness/gate.sh` | One command per gate test: starts the feeder, waits with nothing reading (phase 1), probes (phase 2), stops. `ANNOUNCE=1` speaks the phases aloud for listening tests. | — |
| `harness/default_check.c` + Makefile `default-check` | `rd-default-check`: with the server app's driver installed, checks [decision 0031](../../architecture/decisions/0031-virtual-mic-can-be-the-default-input.md)'s defaults (below). Sets each default and puts it back | — |

## What was tested and the result

On a Mac mini (Apple silicon, macOS 15.7.7, Command Line Tools with SDK 26.2), run from
an agent's shell without microphone or audio-capture grants:

1. **Build**: feeder and probe with no warnings; the driver as a universal bundle exporting
   `BlackHole_Create`, with the device names and UIDs set by the constants. BlackHole.c
   itself gives 7 `-Wformat-extra-args` warnings (device names without a `%i`), upstream
   code left as it is. **PASS**
2. **Device list**: `rd-mic-probe --list` shows every device with its input and output
   channels (including Zoom's and Teams' own virtual devices on this Mac). **PASS**
3. **Option A without the driver**: the feeder exits with `'!dev'` and a pointer to
   `make install-driver`. **PASS**
4. **Option B publishes the device**: with `--mute muted`, another process sees
   "Remote Display Microphone" as **input-only** (2 in, 0 out). It disappears when the
   feeder exits. **PASS**
5. **Option B carries the signal**: the probe recorded 10 s from it and got only digital
   silence. **INCONCLUSIVE**: neither process had a microphone or audio-capture grant
   (see 6).
6. **Recording a real microphone from the same shell**: `AudioDeviceCreateIOProcIDWithBlock`
   blocks in coreaudiod's TCC check, waiting for a consent prompt (stack sampled). Stopped.

### Phase 0 gate tests

Run 2026-10-24 on the same Mac, from the Claude app's Terminal panel, with a person
listening at the speakers and typing the admin password.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | B, muted | `ANNOUNCE=1 ./gate.sh b-muted` | Probe PASS; the speakers stay silent throughout | **PASS**: 10/10 bursts, peak 0.300 (as sent), silent in both phases |
| 2 | B, muted when tapped | `ANNOUNCE=1 ./gate.sh b-when-tapped` | Record whether bursts are audible until something reads the device (the review's A-5 case) | **Confirmed**: beeps in phase 1 only, stopping once the probe reads; probe PASS. Option B must use `CATapMuted` |
| 3 | B, permission | Tests 1–2 | Record which prompts appear | **No prompts** for the tap, the aggregate or reading it. Not yet tried on a Mac that never granted anything |
| 4 | B in apps | Zoom, Teams, Dictation: pick Remote Display Microphone with the feeder running | The input meter jumps once a second | Not run; moot after decision 0013 |
| 5 | B restart | Kill the feeder while Zoom uses the device, then restart it | Record what Zoom does | Not run; moot after decision 0013 |
| 6 | A, install | `make && sudo make install-driver` | coreaudiod restarts without a reboot; Remote Display Microphone lists with 2 in, 0 out, and no feeder device | **PASS** after a fix: `launchctl kickstart -k` is refused with SIP on (error 150), `killall coreaudiod` works. The ad-hoc-signed driver loads; the feeder is hidden from the list and found by UID |
| 7 | A, signal | `./gate.sh a-signal` | Probe PASS | **PASS**: 10/10 bursts, peak 0.300, exactly 24,000 non-zero samples |
| 8 | A in apps | As test 4 | As test 4 | Pending |
| 9 | A, never an output | system_profiler and CoreAudio | Remote Display Microphone has no output channels and can't become a default device | **PASS**: system_profiler shows 2 input channels and no output; `CanBeDefaultDevice` and `CanBeDefaultSystemDevice` are 0 on both devices; the feeder is hidden |
| 10 | A, persistence | Stop the feeder; restart the Mac | The device stays (silent), so the choice in Zoom sticks | Pending (reboot) |
| 11 | A, uninstall | `sudo make uninstall-driver` | The device is gone without a reboot; the HAL folder is as before | **PASS**: device gone; the HAL folder holds the same four third-party drivers as before the test |
| 12 | Latency | Probe medians from tests 1 and 7 | Record per option | A: **0.0 ms**; B: **32 ms**, steady to 0.1 ms. These are timestamp offsets: they include buffering between devices but not the one I/O cycle (about 10 ms) every input path has |

### Phase 2: the engine's path

Run 2026-10-29 on the same Mac, from the Claude app's Terminal panel, with a person
typing the admin password for `a-install` and `a-uninstall`. `make engine` runs the
`#[ignore]`d engine test
`server::device_forward::mic::tests::plays_a_controllers_bursts_into_remote_display_microphone`,
which opens Remote Display Microphone exactly as an accepted forward does. It then sends
14 s of 10 ms Opus frames at 48 kHz mono, paced like a live microphone, with a 1 kHz tone
at 0.3 for the first 250 ms of every whole second of host time. Meanwhile the probe
records 10 s. Each onset modulo one second is the delay from a frame reaching the host
to its sound in the device.

| Run | Probe | Delay (min / median / max) | Peak | Engine |
|---|---|---|---|---|
| 1 | **PASS**, 10 bursts | 48.2 / 48.6 / 49.2 ms | 0.423 | 14.00 s played; 0 dropped; 1 underrun |
| 2 | **PASS**, 10 bursts | 53.7 / 54.0 / 54.5 ms | 0.478 | the same |
| 3 | **PASS**, 9 bursts | 54.7 / 55.2 / 57.1 ms | 0.335 | the same |

- **Delay.** The jitter buffer's 40 ms target, Opus's few milliseconds, and one I/O cycle
  of the device. Each run is steady to within about 2 ms. Mic latency end to end also
  has the controller's capture and the network; the spec's target is 150 ms on a LAN.
- **No glitches.** Every sample sent was played. The one underrun is where the frames
  stopped, and nothing was dropped at the decode queue or the buffer.
- **Level.** Runs 1 and 2 computed each frame's tone phase from the clock when it was
  sent, so the phase jumped slightly between frames. Opus turned those clicks into
  overshoots, and the peaks were above the 0.3 sent. Run 3's tone is continuous, and its
  0.335 is close to what was sent. The engine's `audio_rechannel`, which turns the
  controller's mono into the device's stereo, keeps the level: 0.3 in gives 0.3 in each
  channel (measured separately with fon 0.6).
- **Nothing left behind.** After `a-uninstall` the HAL folder holds the same four drivers
  as before, and the probe lists no Remote Display device.

### Default input (decision 0031)

The first live session found Remote Display Microphone missing from System Settings ›
Sound › Input ([live session](../live-session/README.md)). The server app's driver
(build 2) can now be the default input. This harness's own driver keeps the constants
its tests measured.

**Not run yet:** it needs an admin. With the server app's driver installed,
`make default-check` passes when:

- Remote Display Microphone is listed and becomes the default input when set;
- neither it nor the feeder becomes the default output or the system output;
- the feeder stays out of the device list.

By hand, Sound › Input should list it and Sound › Output shouldn't. Built without
installing, the driver answers "can be default" on both devices, and the feeder is
hidden (decision 0031).

## Runtime findings

- **`killall coreaudiod`, not `launchctl kickstart`.** With SIP on (macOS 15.7),
  `launchctl kickstart -k system/com.apple.audio.coreaudiod` fails with error 150,
  "Operation not permitted while System Integrity Protection is engaged". Killing
  coreaudiod as root lets launchd restart it, which is what BlackHole's own installer
  does. Audio drops for about a second.
- **An ad-hoc-signed HAL driver loads.** coreaudiod loaded our unsigned-by-a-team build,
  so contributor builds can test Option A without a developer account.
- **`CATapMuted` keeps Option B silent; `CATapMutedWhenTapped` doesn't.** The SDK's
  `CATapMuteBehavior` has three values. With muted-when-tapped the bursts played from
  the speakers until the probe started reading (test 2), exactly the review's warning.
  With muted they never reached the speakers while the tap still carried them (test 1).
- **Reading a virtual input didn't prompt; opening a real microphone did.** From the
  Terminal panel, neither the tap, the aggregate, nor reading Remote Display Microphone
  asked for consent. From an agent's background shell, reading the aggregate gave digital
  silence, and opening the USB microphone blocked in TCC.
- **A tap-only aggregate is input-only.** Without the output subdevice that Apple's
  sample adds for its clock, the aggregate has no output channels, so it can't be picked
  as a speaker. Option B gets that property for free; test 9's question doesn't arise.
- **Option B's device lives only as long as its process.** It vanished when the feeder
  exited. The spec wants "the devices exist even between sessions, so the choice sticks":
  `remotedisplayd` runs whenever the server runs, but an engine restart or crash takes
  the device away mid-call. Test 5 measures how Zoom copes.
- **Object IDs differ between processes.** The feeder reported aggregate 147; the probe
  saw the same device as 113. Pass device UIDs between processes, never `AudioObjectID`s.
- **Opening a real input blocks until TCC answers.** `remotedisplayd` and the client must
  never open an input device on a thread that something else waits on.
- **BlackHole already supports decision 0013's layout.** Its mirror constants
  (`kDevice_HasOutput=false`, `kDevice2_IsHidden=true`, `kDevice2_HasInput=false`) give a
  visible input-only device and a hidden output-only one sharing a buffer, with no code
  changes; upstream documents this pairing.

## Re-running

In Terminal, from this folder:

```sh
cd harness
make                                   # feeder, probe, driver (fetches BlackHole v0.7.2)

# Option B: no install, nothing left behind when the feeder exits
ANNOUNCE=1 ./gate.sh b-muted
ANNOUNCE=1 ./gate.sh b-when-tapped     # listen: beeps in phase one only

# Option A: needs an admin; uninstall restores the HAL folder
./gate.sh a-install
./gate.sh a-signal
source <toolchains>/env.sh && make engine   # Phase 2: the engine's own path
./gate.sh a-uninstall

# Decision 0031: the server app's driver (cd ../../../../server-mac && make first)
D="../../../../server-mac/.build/Remote Display Server.app/Contents/Library/Audio/Plug-Ins/HAL/RemoteDisplayMicrophone.driver"
sudo sh -c 'rm -rf /Library/Audio/Plug-Ins/HAL/RemoteDisplayMicrophone.driver && cp -RX "$0" /Library/Audio/Plug-Ins/HAL/ && killall coreaudiod' "$D"
make default-check                     # then look at Sound › Input and Output
sudo sh -c 'rm -rf /Library/Audio/Plug-Ins/HAL/RemoteDisplayMicrophone.driver && killall coreaudiod'
```

`LEVEL` sets the burst volume (default 0.3, or 0.1 for muted-when-tapped), `LISTEN` the
seconds with nothing reading, `DURATION` the probe's seconds. Before installing, note
what's in `/Library/Audio/Plug-Ins/HAL/`; after `a-uninstall` it should match.
