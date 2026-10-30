# 0027. Remote Display Microphone ships in the server app, BlackHole vendored, installed by an admin AppleScript

- **Status:** Accepted, 2026-10-29 (issue #3)
- **Original design:** Follows the spec's Packaging, "ship the driver inside the app and
  install it with an admin prompt". Settles what decision 0015 left to Phase 2: vendoring
  BlackHole rather than a pinned fetch, as decision 0022 vendored cpal. Follows decision
  0019's shape for the camera extension (built by `server-mac/Makefile`, Setup's row, the
  shared removal button) and upstream RustDesk's way of running admin steps on macOS.

## Context

- **What's measured.** The Phase 0 harness builds BlackHole v0.7.2 (commit `561d934`)
  with our constants and measured it installed: input-only, bit-exact, a clean uninstall
  (decisions 0013, 0015). The engine plays into its hidden feeder, 49–55 ms end to end
  (decision 0021). The harness fetches BlackHole with git, and `sudo make install-driver`
  copies the driver and restarts coreaudiod.
- **What the app has.** Setup's Microphone row said "Not available in this build", and
  Settings' *Remove Camera and Microphone* removed only the camera. The engine already
  writes who sends the microphone to `remotedisplay-forwarding.json`
  (`{"microphone": …}`), but the app read only `camera`.
- **Admin steps.** Upstream RustDesk installs its service on macOS with AppleScript
  run through `osascript`: `do shell script … with prompt … with administrator
  privileges`, with its paths passed as arguments and quoted with `quoted form of`
  (`src/platform/privileges_scripts/`). The server app has no admin step yet.
- **BlackHole's licence** is GPL-3.0, which AGPL-3.0's section 13 lets us combine with. It
  also reserves the BlackHole name and branding for official builds.

## Decision

- **Vendored.** `server-mac/AudioDriver/BlackHole/` is `BlackHole.c` and `LICENSE` at
  `561d934`, unmodified, imported in a commit of its own. The build needs no network,
  and a change to it shows in review. There's no update script: BlackHole is one file,
  and moving to a new tag is a reviewed copy plus the harness's measurements again.
- **Built by `server-mac/Makefile`** (`make driver`): universal, with the harness's
  constants unchanged except the bundle ID, `app.remotedisplay.server.mic`.
  `AudioDriver/Info.plist` is the harness's, with that ID. Built from the vendored file
  with the harness's identifier, the driver has the same code as the harness's measured
  one; only link metadata differs.
- **Bundled in every build** at
  `Contents/Library/Audio/Plug-Ins/HAL/RemoteDisplayMicrophone.driver`, mirroring where
  it's installed. It needs no provisioning profile. It's **signed on its own** with its
  identifier and the hardened runtime, before `remotedisplayd`, in Developer ID and
  ad-hoc builds alike: codesign doesn't count `Library/Audio` as nested code, so `--deep`
  would leave it with only the linker's signature.
- **Its version is its own** (`CFBundleVersion` in `AudioDriver/Info.plist`), not the app's.
  Each install asks for an admin, so an app release that doesn't change the driver
  shouldn't ask again.
- **Setup's Microphone row** (`MicrophoneDriver.swift`) compares the bundled and the
  installed driver's identifier and version:
  - *Install…* when there's none;
  - *Update…* when another is there, such as the harness's;
  - *Installed* when they match;
  - "Not available in this build" when none is bundled.

  Install runs upstream's kind of AppleScript through `osascript`, in one admin prompt:
  remove any installed copy, `cp -RX` the bundled one to `/Library/Audio/Plug-Ins/HAL`,
  then `killall coreaudiod` (decision 0013). Cancelling the prompt isn't an error;
  any other failure shows in the row.
- ***Remove Camera and Microphone*** removes whichever is there: it deactivates the camera
  extension and deletes the driver, with an admin prompt, then restarts coreaudiod.
- **The badge.** The menu-bar icon gains a mic badge, and the menu a *Microphone from …*
  line, from the file's `microphone`, as the camera's come from `camera`.

## Consequences

- Every build carries the driver: 464 KB, of which the code is 137 KB and the rest the
  icon. A host owner who never turns on the microphone never installs it.
- Installing or removing restarts coreaudiod: the Mac's sound stops for about a second,
  which the admin prompt says.
- The driver's code keeps two BlackHole names that its constants can't change: function
  and log names, and its audio "box", named "BlackHole Box". Changing them would mean
  modifying the source, which decision 0015 avoids. The device users pick, its
  manufacturer and its bundle say Remote Display.
- **Tested** without an admin (2026-10-29):
  - the driver's state from the two bundles, in six cases;
  - the row and the Settings button, rendered offscreen from the real view in every
    state;
  - the install and remove scripts, run unprivileged on paths with spaces. The copy
    replaced a stale one, its signature verified, and no extended attributes came along.

  **Not yet:** the admin prompt itself, and a real install, update and removal. Those
  need an admin; until then the harness's `sudo make install-driver` is the measured
  way in.
