# Live session — Phases 2 and 3 (2026-10-30)

The first session between two Macs: a controller running the client, and a host running
the server app with Remote Display Microphone installed from Setup. Checks what the unit
and device tests couldn't: the host's sound heard on a controller, a controller's
microphone arriving in the host's virtual mic, the sound switch's status, and installing
and removing the driver from the app (issues #3 and #4, [spec](../../specs/camera-audio-forwarding.md)
Testing plan).

**Status:** the host's sound plays cleanly on the controller, the controller's
microphone reaches Remote Display Microphone, and the controller doesn't hear itself
back. Setup installs the driver and Settings removes it, each with one admin prompt
([results](#what-was-tested-and-the-result)). Two findings: Remote Display Microphone
isn't listed in System Settings › Sound › Input, and without Screen Recording the
session never gets as far as showing the sound switch ([findings](#runtime-findings)).

## What's here

| Piece | What it is |
|---|---|
| `harness/host.sh` | Run on the host. `before` stops if Remote Display is already there, saves a list of the places the test writes to, moves the app to /Applications and clears AirDrop's quarantine. `after` quits the app, removes its LaunchAgent, config, logs and the driver (with `sudo` if Settings didn't), resets the app's permissions, and compares the list with `before`'s |

To run it, put the server app (`server-mac/.build/Remote Display Server.app`) and
`host.sh` in one folder and AirDrop it to the host.

## What was tested and the result

Run 2026-10-30. A person at both Macs did the steps and typed the admin passwords.

- **Host:** MacBook Pro, Apple silicon. It ran the server app built ad-hoc from this
  branch (engine on RustDesk 1.5.1, no camera extension, which needs provisioning
  profiles).
- **Controller:** Mac mini, Apple M4, macOS 15.7.7. It ran the client built from the same
  commit, with its built-in speakers at 25% and a USB webcam's microphone (Microsoft
  LifeCam HD-3000).
- **Network:** both on the same LAN by IP, round trip 6–8 ms.

| # | Test | How | Result |
|---|---|---|---|
| 1 | Install the microphone driver from the app | Setup › Microphone › *Install…*, admin password | **PASS**: one admin prompt, then *Installed · choose Remote Display Microphone in FaceTime, Zoom or any app* |
| 2 | Sound switch without Screen Recording | Connect before granting Screen Recording on the host | **The host's half passes**: the login response carries `rd_host_sound: "unavailable"` (client log). The switch couldn't be seen: the client stays on *Connected, waiting for image*, and that dialog covers the toolbar |
| 3 | With Screen Recording | Grant it on the host, reconnect | **PASS**: the picture shows, `rd_host_sound: "ready"` |
| 4 | Owner's switch mid-session | Turn on *Let controllers share their camera and microphone* while connected | **PASS**: the client logged `Host's MICROPHONE: ready` without reconnecting, and the microphone could be turned on in the same session |
| 5 | Host's sound | `say` counting to 30 on the host, *Play the Mac's sound here* on | **PASS**: heard clean throughout and in step with the picture. The playback trimmed nothing while it played. Before that, a single `say` was heard too |
| 6 | Controller's microphone | Devices › Microphone on with the LifeCam; QuickTime's New Audio Recording on the host, set to Remote Display Microphone | **PASS**: QuickTime's level follows speech. Three forwards sent 13,033, 788 and 31,686 frames, 0 dropped |
| 7 | Own voice back | Both switches on, talking | **PASS**: no echo. Host sound leaves out `remotedisplayd`'s own audio, and this is the first run with the vendored cpal itself ([decision 0022](../../architecture/decisions/0022-vendored-cpal-excludes-own-audio.md)) |
| 8 | Remove the driver from the app | Settings › *Remove Camera and Microphone*, admin password | **PASS**: QuickTime no longer lists Remote Display Microphone |
| 9 | Nothing left behind | `host.sh after` on the host; the client's files removed on the controller | **PASS**: on the host only the volume line differed, from listening; on the controller the home folder's lists match those from before, and the client's permissions are reset |

## Runtime findings

- **Remote Display Microphone isn't in System Settings › Sound › Input.** The list
  showed only the MacBook Pro's microphone and a Bluetooth headset. The driver is built
  with `kCanBeDefaultDevice=false` ([decision 0013](../../architecture/decisions/0013-virtual-mic-input-only-driver.md)),
  meant to keep it out of Sound › Output. It also keeps it out of Input, and it can't be
  the Mac's default input. Apps with their own picker, such as QuickTime, still list it,
  which matches Setup's wording. An app that only uses the default input can't use it,
  and the Phase 2 gate names Dictation.
- **Without Screen Recording there's no session to show the switch in.** The client
  waits for the first frame behind a modal dialog. On a macOS 14+ host the only
  "unavailable" case is Screen Recording being off, so the switch's note
  ([decision 0028](../../architecture/decisions/0028-host-sound-status.md)) is only
  reached if a later client lets the Devices menu through that dialog. The spec's
  *Speakers, no ScreenCaptureKit* test can't pass as written.
- **The speaker path trims at starts.** Each trim drops about 61 ms (5,888 samples)
  when more than 100 ms is waiting ([decision 0030](../../architecture/decisions/0030-engine-rustdesk-1-5-1.md)).
  - At the two session starts: 2 and 4 trims within a few seconds, while the output
    device opened.
  - When the host's sound started again: twice for a single `say`, once later. Upstream's
    host stops sending after about 8 s of silence (`MAX_AUDIO_ZERO_COUNT`), and the first
    frames after that came bunched.

  The log is throttled to one line per 5 s with a count of the rest, so these 9 trims
  show as 4 lines.

  The 30-count, played straight through, had none. A clipped first word after silence
  is what to listen for on Tailscale.
- **macOS notifies the host's owner** that "remotedisplayd can run in the background"
  when the app adds its LaunchAgent. The entry is under General › Login Items &
  Extensions.
- **AirDrop quarantines the ad-hoc build,** so Gatekeeper would block it. `host.sh
  before` clears it. A Developer ID build that's notarized wouldn't need this.
- **Upstream 1.5.1's LAN discovery** probes every address on the subnet on port 21118.
  On first launch the client logged *No route to host* for each one, then connected by
  IP normally.

## Not yet tested

- The camera: an ad-hoc build leaves the extension out.
- Zoom, Teams and Dictation on the host using Remote Display Microphone: the Phase 2
  gate.
- Measured microphone latency (the spec's clap test, under 150 ms), and lip sync.
- Tailscale and a busy network, for gaps in the host's sound.
- *Play the Mac's sound here* off with the microphone on.
- Whether upstream's `static_refresh` makes our restart on a static screen redundant.
- Updating an installed driver (Setup's *Update…*), and a reboot with the driver
  installed.
