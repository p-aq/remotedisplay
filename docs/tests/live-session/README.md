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

In the camera session (2026-11-19, paused before test 10) Remote Display Camera installed and
updated without trouble, and the controller's camera reached Photo Booth, FaceTime, QuickTime,
Zoom, Teams, Safari and Chrome at 1280×720 and 30 fps, about 236 ms glass to glass. But only
on a test build: the real extension refuses `remotedisplayd`
([notes](#run-on-2026-11-19-paused-before-test-10), decision 0033).

The session finished on 2026-11-21 ([notes](#run-on-2026-11-21-tests-10-to-23)):
- decision 0033 is settled: one feeder at a time (option 2), and the engine restarts when the
  camera is new (option A);
- tests 10–18 and 20–23 pass, with lip sync at +58 ms and the microphone at 124 ms;
- test 19 (Tailscale), Phase 1's gate, is still to do.

## What's here

| Piece | What it is |
|---|---|
| `harness/host.sh` | Run on the host. `before` stops if Remote Display is already there, Remote Display Camera included. It saves a list of the places the test writes to and of the Mac's system extensions, moves the app to /Applications, clears AirDrop's quarantine and leaves `installed.txt` beside itself. `after` removes only with that file there, so a `before.txt` left from an earlier session can't make it delete an install the test didn't add. It stops while Remote Display Camera is still installed, since only the app can remove it, and when it can't read the system extensions. Otherwise it quits the app, removes its LaunchAgent, config, logs and the driver (with `sudo` if Settings didn't), resets the app's permissions, and compares the list with `before`'s. If the camera finishes uninstalling at a restart, it says so: run it again after the restart. It deletes `installed.txt` once nothing of the test is left |
| `harness/controller.sh` | The same for the client, on a controller that didn't build it: `before` moves it to /Applications, `after` removes its config, logs and permissions |
| `harness/profiles.sh` | On the build Mac, before a build with the camera: checks both provisioning profiles against what `server-mac/Makefile` signs. It checks each profile's team, App ID, platform and expiry, the install entitlement, the app group, the host Macs and the signing identity's certificate, then prints the `make` command. macOS itself only refuses a wrong profile on the host, at launch or activation |
| `harness/clap.m`, `harness/Makefile` | `rd-clap`, run on the host: records a reference microphone and Remote Display Microphone at once, and gives each clap's delay between the two ([what the figure includes](#what-rd-claps-figure-includes)). `make latency` runs it as `rd-clap.app`, so microphone access goes to it alone. `make clap-test` checks the onset detection and the pairing on generated claps, and `make clean` resets its access and deletes it |
| `harness/lipsync.m` | `rd-lipsync` (`make lipsync`, `lipsync-test`, `lipsync-clip`): test 10's lip sync from a QuickTime recording. It pairs each flash in the picture with its beep or clap in the sound, and writes contact sheets of the frames around each sound for claps read by eye |
| `harness/sink_probe.m` | Starts Remote Display Camera's sink as `remotedisplayd` does, to see whether the extension accepts a given program as its feeder ([decision 0033](../../architecture/decisions/0033-who-may-feed-the-camera.md)) |

To run a session, put the server app (`server-mac/.build/Remote Display Server.app`) and
`host.sh` in one folder and AirDrop it to the host. For a controller other than the build
Mac, do the same with the client (`client/build/macos/Build/Products/Release/RemoteDisplay.app`)
and `controller.sh`.

### What rd-clap's figure includes

- **From:** the clap reaching the reference microphone. Core Audio stamps a sample when
  the device acquired it, so `rd-clap` adds the input latency the reference reports (its
  device latency plus its stream's). If Core Audio's stamps already allow for it, the
  figure reads high by that much, which is the safe side of the limit.
- **To:** the clap's first sample in Remote Display Microphone, by the device's own stamp.
  An app reading the device gets that sample one of its own buffers later, about 10 ms at
  512 frames, which the figure leaves out.
- **The reference:** the first built-in or wired input, unless `REF=` names another. A
  Bluetooth or virtual input stamps its samples late. If Remote Display Microphone hears
  most claps before the reference does, `rd-clap` says so and gives no figure.
- **Pairing:** a clap counts when Remote Display Microphone hears it before the reference
  hears the next one. A sound only one of them hears stays unpaired. Clap every two
  seconds or so.

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

Set up on 2026-11-14 ([results](#set-up-on-2026-11-14)); run on 2026-11-19 up to test 9, then
paused ([notes](#run-on-2026-11-19-paused-before-test-10)). The
camera needs a build signed by a paid Apple Developer Program team. macOS installs a camera extension only from an app whose
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
3. **Devices.** Add each Mac that will host under macOS, by its Provisioning UDID (System
   Information › Hardware). A Mac added later means generating the profiles again.
4. **Profiles.** Add a *macOS App Development* profile for each App ID, with the Apple
   Development certificate and those Macs, and download them. Keep them out of the
   repository: they name the team and the Macs.
5. **Check, then build.** On the build Mac:

   ```sh
   bash docs/tests/live-session/harness/profiles.sh TEAM_ID server.provisionprofile camera.provisionprofile [HOST_UDID...]
   ```

   It checks the profiles for each host given, or for this Mac when none is, and prints
   the `make` command once every check passes.

A development build needs no notarization. A Developer ID system extension loads only
once notarized (spec, Packaging), so Developer ID waits for the release build. If macOS
refuses to activate the extension, `log stream --predicate 'process == "sysextd"'` on
the host says why.

#### Set up on 2026-11-14

On the Mac mini (macOS 15.7.7, Xcode 26.3), with an individual team. Only the Mac mini is
registered, since it hosts.

- **`profiles.sh`:** all 16 checks pass on the two profiles.
- **The build:** `make sign` with the team, the identity and both profiles bundles Remote
  Display Camera. The extension, `remotedisplayd` and the app carry the Apple Development
  signature, each of the app and the extension embeds its profile, the app claims the
  install entitlement, and `codesign --verify --deep --strict` passes.
- **Not yet:** installing it. Activation, and every test below, needs a person at the Mac.

Two things stood in the way:

- **`codesign` couldn't use the new certificate:** "unable to build chain to self-signed
  root", then `errSecInternalComponent`. Apple Development certificates are issued by the
  Worldwide Developer Relations G3 intermediate, and this Mac's keychains held only the
  ones that expired in 2016 and 2023. Xcode hadn't installed G3. `security verify-cert`
  passed all the same, because it fetches a missing intermediate and `codesign` doesn't.
  Adding `AppleWWDRCAG3.cer` from apple.com/certificateauthority to the login keychain
  fixed it, after checking that it chains to Apple Root CA and that its key ID is the
  certificate's issuer.
- **`make sign` needs Xcode's toolchain:** with the Command Line Tools selected, the
  universal `swift build` stops at "xcbuild … does not exist". Run it with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The portal also turns on In-App Purchase for every new App ID. It's harmless here, and the
profiles don't carry it.

#### Run on 2026-11-19 (paused before test 10)

The Mac mini hosted on macOS 27.2.1, upgraded from 15.7.7 since the setup above; the
MacBook Pro controlled on macOS 26.7.3. Results are in the table below.

- **The extension refused `remotedisplayd`.** Both of decision 0019's checks fail on a real
  Mac: CoreMediaIO reports every sink client's signing identifier as `unknown`, and the
  sandboxed extension may not look up another process's code (EPERM). A build with the
  camera entitlement on `remotedisplayd` was refused the same way. Tests 3 to 9 ran on a
  test build (version 19) that lets any feeder in; it is never to ship. Options and the next
  test: [decision 0033](../../architecture/decisions/0033-who-may-feed-the-camera.md).
- **Issue #7:** feeding the sink took no Camera permission and showed no prompt. But when
  the extension's device appeared after `remotedisplayd` had started, CoreMediaIO checked
  the Camera permission for it ("requires entitlement com.apple.security.device.camera but
  it is missing"), and that engine never saw the device until it restarted.
- **Every camera failure reaches the controller as `not-installed`,** so it said *Remote
  Display Camera isn't installed on this Mac* while it was installed and the extension was
  refusing the feeder.
- **Xcode updated itself to 27.2** overnight; the next build stopped until the host's admin
  accepted its license (`sudo …/xcodebuild -license accept`).
- **The microphone forward ran during test 3:** about two minutes, 4 underruns, before the
  microphone tests proper.

#### Run on 2026-11-21 (tests 10 to 23)

Same Macs. Each build ran on the 2026-11-18 engine. Build 25 (PRs #61, #64 and #68) ran from
test 10 on; it accepts any feeder, one at a time, and restarts the engine when the camera is
new.

- **Option 1 can't work.** Version 20 (#61) gets each feeder's path, but its sandbox may not
  read the file: EACCES under the user's temp folder, and EPERM under `/Applications` for
  `remotedisplayd` and for a test feeder signed with the real requirement.
- **Option 2 passes:**
  - the engine feeds the camera with no warning;
  - a second feeder is refused while it does;
  - a feeder that came first is named in the server app's menu (*Another program, p1, is
    feeding Remote Display Camera*), and the controller's camera is refused until it stops.
- **After an extension update, running programs don't get the new camera.**
  - The engine, Photo Booth and Safari all lost it.
  - Camera access for the engine (option B) didn't help. TCC answered *allowed* for the
    running engine, and it still never got the device.
  - A restarted engine got it.
  - So the app now restarts the engine after an update or an approval (option A, #68), and
    tells the owner to reopen apps that use the camera. Teams, running through the
    updates, needed reopening (test 18).
- **While the engine runs without the app, Launch Services counts the engine as Remote
  Display Server.** It sits in the app's `Contents/MacOS` with the app's identifier. So
  opening the app does nothing, and a scripted quit reaches the engine. `open -n` works
  around it.

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
| 1 | Install the camera | Setup › Camera › *Install…*, then allow it in System Settings › General › Login Items & Extensions › Camera Extensions, with the controller connected | `systemextensionsctl list` shows `app.remotedisplay.server.camera` `[activated enabled]`, Setup says it's installed, and the controller's Camera row becomes available without reconnecting | Host side **PASS** (2026-11-19): `[activated enabled]` after one approval. Installed before the controller connected, so the row's live update wasn't seen. OBS Virtual Camera, waiting for approval, was enabled by the same approval |
| 2 | Placeholder | Photo Booth, Remote Display Camera, nothing forwarded | The *No controller connected* card | **PASS**: the card (Photo Booth mirrors its preview) |
| 3 | The test card | Open the client with `--camera-test-pattern`, then Devices › Camera › *Test pattern* | Photo Booth shows the card and its clock moves smoothly. The extension accepts `remotedisplayd` (its log). Record whether macOS asks for camera access for Remote Display Server (spec, Open questions) | **FAIL** with the real extension, which refused `remotedisplayd` ([decision 0033](../../architecture/decisions/0033-who-may-feed-the-camera.md)). **PASS** with a test build that lets any feeder in: 1280×720 at 30 fps, the clock moving smoothly. No camera prompt (issue #7, below) |
| 4 | The real camera | The MacBook Pro's camera, in Photo Booth, FaceTime, QuickTime, Zoom, Teams and a WebRTC test page in Safari and Chrome | The picture shows in each | **PASS** (test build) in all seven: 1280×720 at 30 fps, 0 frames dropped in the first 2,493 |
| 5 | No reader yet | Camera on, then open Photo Booth 30 s later | A live picture within 1 s | **PASS** (test build) |
| 6 | Owner switches off | Settings › *Let controllers share their camera and microphone* off while forwarding | The forward stops and the controller's menu says why | **PASS** (test build): the card; the controller said *This Mac hasn't turned on camera sharing*. 17 of 15,851 frames dropped before it |
| 7 | Network cut | Turn off the controller's Wi-Fi while forwarding | The placeholder within 1 s; the controller's camera light goes off | **PASS** (test build): the outage was short enough that the connection never closed; the extension's own timer showed the card, and the picture came back with the Wi-Fi |
| 8 | Engine crash | `pkill remotedisplayd` on the host while forwarding | The placeholder within 1 s | **PASS** (test build): the card within about a second; the app started a new engine and the controller reconnected, its camera off |
| 9 | Glass to glass | A stopwatch with milliseconds on the host's screen beside Photo Booth, the controller's camera pointed at it; screenshots on the host | The difference between the two times, recorded | **≈ 236 ms** (test build, LAN, one reading) |
| 10 | Lip sync | QuickTime's *New Movie Recording* on the host from Remote Display Camera and Microphone; clap in view of the controller's camera. Measure with `make lipsync MOVIE=…` in `harness/`; a phone playing `make lipsync-clip`'s flash-and-beep clip in front of the controller is more precise than a clap | The clap's frame against its sound, recorded | **PASS** (build 25; recorded): a phone played `lipsync-clip.mov` in front of the MacBook Pro, and QuickTime on the host recorded Remote Display Camera and Microphone. `make lipsync`: 20 flashes, 19 beeps, **sound +58 ms late** (median; 18 of 19 within ±1 ms), 2 ms drift over 18 s, including the phone's own playback offset. The flash detector now watches the part of the frame that changes most, for a clip in a small window |
| 11 | Default input | `make default-check` in `docs/tests/virtual-mic/harness/`, then look at Sound › Input and Output ([decision 0031](../../architecture/decisions/0031-virtual-mic-can-be-the-default-input.md)) | PASS; Input lists Remote Display Microphone and Output doesn't | **PASS**: `make default-check`. The microphone can be the default input but not an output, the feeder stays hidden, and each default was put back (the input stays the LifeCam) |
| 12 | Dictation | Remote Display Microphone as the input under Sound › Input, then dictate into TextEdit. Turn Dictation on in Keyboard if it's off, and off again after | The words come out right: with 13, the Phase 2 gate | **PASS**: dictated into TextEdit on the host, spoken into the MacBook Pro; the words came out right. With 13, Phase 2's gate is met |
| 13 | Zoom's test meeting | zoom.us/test on the host, with Remote Display Camera and Remote Display Microphone | The preview shows the picture, and the microphone test plays the speech back clearly | **PASS**: the preview showed the MacBook Pro's camera, and Zoom's microphone test played the speech back clearly |
| 14 | Microphone latency | `make latency` on the host, the LifeCam next to the MacBook Pro; clap every two seconds. `rd-clap` takes the LifeCam as the Mac mini's only wired input and says which it took | The median is under 150 ms | **PASS**: `make latency DURATION=30`, the LifeCam (USB, 1.5 ms) as reference. **Median 124 ms** over 8 claps (91–132 ms) |
| 15 | No host sound | *Play the Mac's sound here* off, microphone on | The microphone still reaches the host | **PASS** (from 14): *Play the Mac's sound here* was off while all 8 claps reached the host |
| 16 | A call with the host's sound | A Zoom meeting on the host with the phone, *Play the Mac's sound here* on | The phone and the controller hear each other; echo and ducking recorded (spec, Open questions) | **PASS**: both sides heard each other. No echo while the headset volume stays low; louder, the headphones leak into the MacBook Pro's microphone. No ducking noticed |
| 17 | No headphones | As 16, with the controller on its own speakers and microphone | The phone hears no echo, or the Devices menu shows the headphones hint | **PASS** (run first): both sides heard each other, with no echo on the phone while it was away from the MacBook Pro. The headphones hint wasn't checked by eye; `devices_test.dart` covers it |
| 18 | Teams | Teams' test call on the host, as 13 | As 13 | **PASS**: this Teams has no test call, so Meet now's pre-join screen. After Teams was reopened (it had run through the extension updates), the preview showed the camera and the microphone's level moved |
| 19 | Over Tailscale | 16 again, connected by the host's Tailscale address | The phone sees the controller's camera: the Phase 1 gate | **Not run**: Tailscale can't be installed on the MacBook Pro. Phase 1's gate is still open |
| 20 | Restart | Restart the host with both devices installed | After login the camera and the microphone work without reinstalling | **PASS**: after a restart only the current extension was left, the engine started from its LaunchAgent with the app closed, and the camera and microphone worked once the controller reconnected |
| 21 | Upgrade | Install a newer build over this one with Photo Booth open | What Photo Booth shows, recorded; no stale device once it relaunches | **Mostly PASS**: 17 → 18 → 19, each replaced without asking, with Photo Booth showing the card throughout; the older versions wait to uninstall at the next restart. Photo Booth relaunched after the restart: one Remote Display Camera, no stale device (2026-11-21). Apps running during an update lose the camera until reopened, which #68's note now says |
| 22 | Remove | Settings › *Remove Camera and Microphone* | The extension leaves `systemextensionsctl list`, or says it finishes at a restart; Remote Display Microphone goes | **PASS**: the Camera row said *Removed · finishes when this Mac restarts*, the extension waited to uninstall, and the microphone's driver and device were gone |
| 23 | Nothing left behind | `make clean` in `harness/`, for `rd-clap`'s microphone access; `host.sh after`, again after a restart if it asks; `controller.sh after` | Only the volume line differs | **PASS** after a second restart: `host.sh after` matches `before.txt` but for macOS's own settings (dictation, sign-in, Accessibility) and OBS Virtual Camera, which test 1's approval enabled. `make clean` reset `rd-clap`'s microphone access |

### Still not covered

- Phase 0's harness-only tests: a feeder sending the wrong size and one without the
  camera usage string (`docs/tests/camera-extension/`, tests 6 and 7), and the Tart image
  with the extension approved (test 9).
- Updating an installed driver from build 1 (Setup's *Update…*).
- A busy network, for gaps in the host's sound.
- Whether upstream's `static_refresh` makes our restart on a static screen redundant.
