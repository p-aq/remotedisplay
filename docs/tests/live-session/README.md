# Live sessions — Phases 1 to 3

Sessions between two Macs: a controller running the client, and a host running the
server app. They check what the unit and device tests can't (issues #2, #3 and #4,
[spec](../../specs/camera-audio-forwarding.md) Testing plan). The first, on 2026-10-30,
covered the microphone and the host's sound. The next adds the camera and the calls that
the Phase 1 and Phase 2 gates name ([planned](#next-session-the-camera-and-the-calls)).

**Status:** in the first session the host's sound played cleanly on the controller, the
controller's microphone reached Remote Display Microphone, and the controller didn't hear
itself back. Setup installed the driver and Settings removed it, each with one admin
prompt ([results](#what-was-tested-and-the-result)). Two findings: Remote Display
Microphone wasn't listed in System Settings › Sound › Input, and without Screen Recording
the session never got as far as showing the sound switch ([findings](#runtime-findings)).

## What's here

| Piece | What it is |
|---|---|
| `harness/host.sh` | Run on the host. `before` stops if Remote Display is already there, Remote Display Camera included. It saves a list of the places the test writes to and of the Mac's system extensions, moves the app to /Applications and clears AirDrop's quarantine. `after` stops while Remote Display Camera is still installed, since only the app can remove it. Otherwise it quits the app, removes its LaunchAgent, config, logs and the driver (with `sudo` if Settings didn't), resets the app's permissions, and compares the list with `before`'s. If the camera finishes uninstalling at a restart, it says so: run it again after the restart |
| `harness/controller.sh` | The same for the client, on a controller that didn't build it: `before` moves it to /Applications, `after` removes its config, logs and permissions |
| `harness/profiles.sh` | On the build Mac, before a build with the camera: checks both provisioning profiles against what `server-mac/Makefile` signs. It checks each profile's team, App ID, platform and expiry, the install entitlement, the app group, the host Macs and the signing identity's certificate, then prints the `make` command. macOS itself only refuses a wrong profile on the host, at launch or activation |
| `harness/clap.m`, `harness/Makefile` | `rd-clap`, run on the host: records a reference microphone and Remote Display Microphone at once, and gives each clap's delay between the two from Core Audio's host-time stamps. `make latency` runs it as `rd-clap.app`, so microphone access goes to it alone. `make clap-test` checks the onset detection on generated claps, and `make clean` resets its access and deletes it |

To run a session, put the server app (`server-mac/.build/Remote Display Server.app`) and
`host.sh` in one folder and AirDrop it to the host. For a controller other than the build
Mac, do the same with the client (`client/build/macos/Build/Products/Release/RemoteDisplay.app`)
and `controller.sh`.

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
  and the Phase 2 gate names Dictation. [Decision 0031](../../architecture/decisions/0031-virtual-mic-can-be-the-default-input.md)
  lets it be the default input.
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

## Next session: the camera and the calls

Planned for the weekend of 2026-10-31. The camera needs a build signed by a paid Apple
Developer Program team. macOS installs a camera extension only from an app whose
provisioning profile allows it, and an ad-hoc build leaves the extension out
([decision 0019](../../architecture/decisions/0019-camera-extension-in-the-server-app.md)).
Without one, the microphone and sound tests (11 to 18) still run on an ad-hoc build.

Phase 0's camera gate runs here on the server app's extension rather than the harness's
(`docs/tests/camera-extension/`). It's the same extension under the server's identifiers,
and `remotedisplayd` is the background process feeding it that the gate asks for. The
harness would need two more App IDs and profiles, so it stays the fallback if the
extension refuses `remotedisplayd`.

### Setting up, once

On the build Mac, after joining the program:

1. **Certificate.** Xcode › Settings › Accounts: add the Apple Account, then *Manage
   Certificates…* › + › *Apple Development*. Xcode puts it in the login keychain.
2. **App IDs.** In developer.apple.com › Certificates, Identifiers & Profiles ›
   Identifiers, add two App IDs of type App:
   - `app.remotedisplay.server`, with *System Extension* and *App Groups*;
   - `app.remotedisplay.server.camera`, with *App Groups*.

   Don't register an app group. The portal only takes `group.` IDs, and a Mac profile
   whose App ID has App Groups on covers `<TEAM_ID>.*`, which includes the build's
   `<TEAM_ID>.app.remotedisplay.server` ([Apple DTS](https://developer.apple.com/forums/thread/721701)).
3. **Devices.** Add both Macs under macOS, each by its Provisioning UDID (System
   Information › Hardware), so either can host.
4. **Profiles.** Add a *macOS App Development* profile for each App ID, with the Apple
   Development certificate and both Macs, and download them.
5. **Check, then build.** On the build Mac:

   ```sh
   bash docs/tests/live-session/harness/profiles.sh TEAM_ID server.provisionprofile camera.provisionprofile [OTHER_HOST_UDID]
   ```

   It prints the `make` command once every check passes.

A development build needs no notarization. A Developer ID system extension loads only
once notarized (spec, Packaging), so Developer ID waits for the release build. If macOS
refuses to activate the extension, `log stream --predicate 'process == "sysextd"'` on
the host says why.

### Layout

The Mac mini hosts and the MacBook Pro controls, the reverse of the first session:

- Zoom, Teams and Tailscale are already on the Mac mini. An agent there can read the
  extension's log and macOS's state while the tests run, and activation, the sink check
  and the Camera permission have never run.
- The MacBook Pro brings a built-in camera, microphone and speakers, which the
  controller tests haven't had yet (`docs/tests/camera-capture/`, `docs/tests/mic-capture/`).
- The LifeCam goes on the Mac mini, beside the MacBook Pro, as `rd-clap`'s reference
  microphone.
- The cost: the Mac mini may need a restart to finish removing Remote Display Camera.

OBS Virtual Camera was already waiting for approval in Camera Extensions on the Mac mini
before the test; leave it as it is.

### Tests

Start as in the first session: `host.sh before` and the server app's Setup on the host,
with Remote Display Microphone installed from Setup and *Let controllers share their
camera and microphone* on; `controller.sh before` and the client on the controller,
connected by IP. Then in this order. The host's admin types the passwords and approves
the extension. A phone that joins the Zoom meetings is the far end.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | Install the camera | Setup › Camera › *Install…*, then allow it in System Settings › General › Login Items & Extensions › Camera Extensions, with the controller connected | `systemextensionsctl list` shows `app.remotedisplay.server.camera` `[activated enabled]`, Setup says it's installed, and the controller's Camera row becomes available without reconnecting | Pending |
| 2 | Placeholder | Photo Booth, Remote Display Camera, nothing forwarded | The *No controller connected* card | Pending |
| 3 | The test card | Open the client with `--camera-test-pattern`, then Devices › Camera › *Test pattern* | Photo Booth shows the card and its clock moves smoothly. The extension accepts `remotedisplayd` (its log). Record whether macOS asks for camera access for Remote Display Server (spec, Open questions) | Pending |
| 4 | The real camera | The MacBook Pro's camera, in Photo Booth, FaceTime, QuickTime, Zoom, Teams and a WebRTC test page in Safari and Chrome | The picture shows in each | Pending |
| 5 | No reader yet | Camera on, then open Photo Booth 30 s later | A live picture within 1 s | Pending |
| 6 | Owner switches off | Settings › *Let controllers share their camera and microphone* off while forwarding | The forward stops and the controller's menu says why | Pending |
| 7 | Network cut | Turn off the controller's Wi-Fi while forwarding | The placeholder within 1 s; the controller's camera light goes off | Pending |
| 8 | Engine crash | `pkill remotedisplayd` on the host while forwarding | The placeholder within 1 s | Pending |
| 9 | Glass to glass | A stopwatch with milliseconds on the host's screen beside Photo Booth, the controller's camera pointed at it; screenshots on the host | The difference between the two times, recorded | Pending |
| 10 | Lip sync | QuickTime's *New Movie Recording* on the host from Remote Display Camera and Microphone; clap in view of the controller's camera | The clap's frame against its sound, recorded | Pending |
| 11 | Default input | `make default-check` in `docs/tests/virtual-mic/harness/`, then look at Sound › Input and Output ([decision 0031](../../architecture/decisions/0031-virtual-mic-can-be-the-default-input.md)) | PASS; Input lists Remote Display Microphone and Output doesn't | Pending |
| 12 | Dictation | Remote Display Microphone as the input under Sound › Input, then dictate into TextEdit. Turn Dictation on in Keyboard if it's off, and off again after | The words come out right: with 13, the Phase 2 gate | Pending |
| 13 | Zoom's test meeting | zoom.us/test on the host, with Remote Display Camera and Remote Display Microphone | The preview shows the picture, and the microphone test plays the speech back clearly | Pending |
| 14 | Microphone latency | `make latency` on the host, the LifeCam next to the MacBook Pro | The median is under 150 ms | Pending |
| 15 | No host sound | *Play the Mac's sound here* off, microphone on | The microphone still reaches the host | Pending |
| 16 | A call with the host's sound | A Zoom meeting on the host with the phone, *Play the Mac's sound here* on | The phone and the controller hear each other; echo and ducking recorded (spec, Open questions) | Pending |
| 17 | No headphones | As 16, with the controller on its own speakers and microphone | The phone hears no echo, or the Devices menu shows the headphones hint | Pending |
| 18 | Teams | Teams' test call on the host, as 13 | As 13 | Pending |
| 19 | Over Tailscale | 16 again, connected by the host's Tailscale address | The phone sees the controller's camera: the Phase 1 gate | Pending |
| 20 | Restart | Restart the host with both devices installed | After login the camera and the microphone work without reinstalling | Pending |
| 21 | Upgrade | Install a newer build over this one with Photo Booth open | What Photo Booth shows, recorded; no stale device once it relaunches | Pending |
| 22 | Remove | Settings › *Remove Camera and Microphone* | The extension leaves `systemextensionsctl list`, or says it finishes at a restart; Remote Display Microphone goes | Pending |
| 23 | Nothing left behind | `host.sh after`, again after a restart if it asks; `controller.sh after` | Only the volume line differs | Pending |

### Still not covered

- Phase 0's harness-only tests: a feeder sending the wrong size and one without the
  camera usage string (`docs/tests/camera-extension/`, tests 6 and 7), and the Tart image
  with the extension approved (test 9).
- Updating an installed driver from build 1 (Setup's *Update…*).
- A busy network, for gaps in the host's sound.
- Whether upstream's `static_refresh` makes our restart on a static screen redundant.
