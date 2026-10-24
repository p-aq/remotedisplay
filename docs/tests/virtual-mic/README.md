# Virtual microphone — Phase 0 (2026-10-24)

Measures the two ways the host could publish "Remote Display Microphone", an input
device Zoom, Teams and Dictation can pick (issue #1, [spec](../../specs/camera-audio-forwarding.md)
Host side › Microphone, [decision 0013](../../architecture/decisions/0013-virtual-mic-input-only-driver.md)):

- **Option A**: a HAL driver, built from BlackHole, with a visible input-only device and a
  hidden output-only twin that `remotedisplayd` plays into.
- **Option B**: no driver. `remotedisplayd` plays into the default output, taps its own
  output with a Core Audio process tap, and publishes an aggregate device built on the tap.

**Status:** both harnesses build and Option B publishes its device. Whether audio gets
through, and what Zoom and Teams make of each option, needs an interactive Terminal
session (permission prompts) and, for Option A, an admin password. Results go in the
tables as they come in; then decision 0013 is accepted or superseded.

## What's here

| Harness | What it is | Becomes in Phase 2 |
|---|---|---|
| `harness/mic_sink.mm`, `.h` | Opens either option and plays whatever a render callback supplies, once per I/O cycle. `extern "C"` `MacMicSink…` functions, `-std=c++17`, no ARC, like `src/platform/macos.mm`. | Engine code behind the host's mic routing; the callback reads the low-latency jitter buffer ([decision 0008](../../architecture/decisions/0008-mic-path.md)) |
| `harness/mic_feeder.mm` | `rd-mic-feeder --option a\|b`: a 50 ms, 1 kHz burst at every whole second of host time. Option B takes `--mute muted\|when-tapped\|unmuted` and `--with-output-subdevice`. | Replaced by decoded controller audio |
| `harness/mic_probe.mm` | `rd-mic-probe`: records from an input device like Zoom would, counts bursts and measures latency. Since bursts start on whole host seconds, each onset's time modulo one second is the latency, with no link between the two processes. Exits 0 on PASS. | A Phase 2 test |
| `harness/driver/Info.plist` + Makefile `driver` | Option A: BlackHole v0.7.2 (commit `561d934`) fetched at build time and configured, not modified, with its own build constants ([decision 0015](../../architecture/decisions/0015-virtual-mic-harness.md)). | `server-mac/AudioDriver/` |
| `harness/Makefile` | Builds everything with the Command Line Tools; `install-driver` / `uninstall-driver` need an admin. | Folded into `server-mac/Makefile` |

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

### Phase 0 gate tests (need an interactive session)

Run from Terminal, so macOS asks for consent on Terminal's behalf, and answer the prompts.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | B, muted | `rd-mic-feeder --option b --mute muted`, then `rd-mic-probe` | Probe PASS; the speakers stay silent throughout | Pending |
| 2 | B, muted when tapped | Same with `--mute when-tapped`; listen before the probe starts | Record whether the bursts are audible until something reads the device (the review's A-5 case) | Pending |
| 3 | B, permission | Test 1 on a Mac that never granted Terminal anything | Record which prompts appear (Microphone, System Audio Recording) and for which process | Pending |
| 4 | B in apps | Zoom › Settings › Audio › Microphone, Teams, Dictation: pick Remote Display Microphone with the feeder running | The input meter jumps once a second | Pending |
| 5 | B restart | Kill the feeder while Zoom uses the device, then restart it | Record what Zoom does, and whether it picks the device again by itself | Pending |
| 6 | A, install | `make && sudo make install-driver` | coreaudiod restarts without a reboot; `--list` shows Remote Display Microphone with 2 in, 0 out, and no feeder device (it's hidden) | Pending |
| 7 | A, signal | `rd-mic-feeder --option a`, then `rd-mic-probe` | Probe PASS | Pending |
| 8 | A in apps | As test 4 | As test 4 | Pending |
| 9 | A, never an output | System Settings › Sound › Output, and Zoom's speaker list | Remote Display Microphone isn't offered anywhere as an output | Pending |
| 10 | A, persistence | Stop the feeder; restart the Mac | The device stays (silent), so the choice in Zoom sticks | Pending |
| 11 | A, uninstall | `sudo make uninstall-driver` | The device is gone without a reboot | Pending |
| 12 | Latency | Read the probe's median from tests 1 and 7 | Record it per option (the spec's mic target is under 150 ms end to end) | Pending |

## Runtime findings

- **`CATapMuted` exists.** The SDK's `CATapMuteBehavior` has three values: unmuted,
  muted ("captured by the tap but no audio is sent from the process to the audio
  hardware") and muted-when-tapped. The review's Option B failure (mic audio playing
  from the host's speakers until Zoom opens the device) applies only to
  muted-when-tapped. Tests 1 and 2 check both.
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

# Option B
build/rd-mic-feeder --option b --mute muted &
build/rd-mic-probe --seconds 10
kill %1

# Option A (admin)
sudo make install-driver
build/rd-mic-probe --list | grep "Remote Display"
build/rd-mic-feeder --option a &
build/rd-mic-probe --seconds 10
kill %1
sudo make uninstall-driver
```

`--level` sets the burst volume (default 0.3); use something low when testing modes
that may reach the speakers.
