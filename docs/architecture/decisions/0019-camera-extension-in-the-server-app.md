# 0019. Remote Display Camera ships in the server app, built by its Makefile; only remotedisplayd feeds it

- **Status:** Accepted, 2026-10-28 (issue #2)
- **Original design:** Follows decision 0010 (one entitlements file per binary, the
  extension signed first, without `--deep`, bundled only with a profile) and decision
  0014 (`swiftc` and a Makefile). Departs from the spec's "build the extension with
  xcodebuild from its own target". Adds two things the spec leaves open: which processes
  may feed the sink, and where the Remove button sits.

## Context

- **Build.** Decision 0014 left Phase 1 to decide whether `server-mac/Makefile` builds
  the extension with `swiftc` or moves to `xcodebuild`. The server app has no Xcode
  project: SwiftPM builds it and the Makefile assembles and signs the bundle. The
  harness already built and signed the extension the same way. macOS needs the bundle
  layout, the Info.plist and the signature, not an Xcode build.
- **The sink.** The harness's extension let any process write into its sink; a comment
  left the restriction to Phase 1. Once an admin allows Remote Display Camera, whatever
  writes into that sink shows in meetings as the camera. CoreMediaIO gives the extension
  each client's signing identifier and pid, but not its team.
- **State.** To offer Install…, the approval step or Installed, the app has to know
  where the extension stands. `OSSystemExtensionRequest.propertiesRequest` (macOS 12)
  answers that without admin rights.

## Decision

- **Source.** `server-mac/CameraExtension/` holds the extension, copied from the harness
  with the server's identifiers (`app.remotedisplay.server.camera`, app group
  `<team>.app.remotedisplay.server`).
- **Build.** The Makefile compiles it with `swiftc` for arm64 and x86_64 and joins them
  with `lipo`. It copies the result to
  `Contents/Library/SystemExtensions/app.remotedisplay.server.camera.systemextension`,
  but only when `SIGN_ID`, `APP_PROFILE` and `EXT_PROFILE` are all given. The extension
  takes the app's version numbers, so a new app version updates it
  ([decision 0032](0032-app-update-replaces-the-camera-extension.md) adds the request
  that makes macOS do so).
- **Signing,** as decision 0010:
  - the extension first, with its own identifier, entitlements (sandbox and app group)
    and profile;
  - then `remotedisplayd` with `Entitlements.plist`, unchanged;
  - then the app with `App.entitlements`: `Entitlements.plist` plus the install
    entitlement and the app group.
  - Without the profiles, the build and its signing are the same as before.
- **Profiles are passed by hand,** as in the harness: `make APP_PROFILE=… EXT_PROFILE=…`.
  `release/release-mac.sh` passes them on from `RD_SERVER_PROFILE` and
  `RD_CAMERA_PROFILE`, which `signing.env` can set like `RD_NOTARY_PROFILE`. Neither
  the Makefile nor `codesign` checks that a profile matches the identity; macOS refuses
  a mismatched one at launch or activation.
- **Only `remotedisplayd` may feed the sink.** The extension accepts a sink client only
  if both checks pass:
  - CoreMediaIO reports its signing identifier as `app.remotedisplay.server`;
  - its running code, looked up by pid, satisfies the Makefile's designated requirement
    with the extension's own team:
    `identifier "app.remotedisplay.server" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`.

  Anything else is refused and logged with the reason (subsystem
  `app.remotedisplay.server.camera`). Apps reading the camera aren't checked.

  **Since 2026-11-20** neither check works as written on a real Mac (camera session,
  2026-11-19). CoreMediaIO reports `unknown` for every sink client, and the sandbox refuses
  the lookup by pid. So an identifier of `unknown` now goes on to the signature check, and
  when the lookup is refused, the extension checks the client's program on disk against
  the same requirement. Whether the installed extension may do that is still to be tested.
  The options are in [decision 0033](0033-who-may-feed-the-camera.md) (proposed).
- **The Camera row in Setup** asks macOS on every 2-second refresh and shows one of:
  - not available in this build;
  - move the app to Applications first;
  - Install…;
  - waiting for macOS;
  - an admin must allow it, with Open Settings… for the pane on this macOS version;
  - installed;
  - removed, finishing when the Mac restarts.

  A failed install or removal shows macOS's message on the row until the next try, or
  until the state next changes (decision 0032).
  Answers that arrive while the menu-bar menu is open wait until it closes (the menu
  guard).

  **Since 2026-11-21** (a UX audit Paolo approved):
  - a failed request says what to do instead, in a sentence for each common
    `OSSystemExtensionError` (`CameraExtension.failureMessage`); the log keeps macOS's
    message;
  - while the owner's switch is off (decision 0009), an installed camera says *Installed ·
    turn on sharing to use it*, with *Turn On* while the service runs, and isn't ticked
    until the switch is on. A first install used to end ticked with sharing still off, its
    default. The Microphone row does the same;
  - the approval step says to turn on only Remote Display Camera: in the live session the
    same approval also turned on OBS Virtual Camera, which was waiting in the same list;
  - the warning about another feeder adds *quit it to free the camera* (decision 0033).
- **Removal.** The spec names a *Remove camera and microphone* button but not where it
  goes. It goes in Settings, shown while the extension is installed or waiting for
  approval, so Setup stays a list of what to do. For now it removes the camera
  extension; the microphone's driver joins it in Phase 2.

  **Since 2026-11-21** it asks first: apps that use the camera or microphone lose them, and
  the camera finishes uninstalling when the Mac restarts.
- **The harness stays** as the Phase 0 record and test bed, with its own identifiers
  (`app.remotedisplay.spike`). Its sink and codec code stayed there the same way when
  they moved into the engine.

## Consequences

- Contributor and ad-hoc builds are unchanged and never carry the restricted
  entitlement.
- No Xcode project to keep in sync. The extension is compiled without Xcode's
  per-target settings, as in the harness.
- To feed the camera, a local process can't just sign itself as
  `app.remotedisplay.server`: it would need the team's certificate.
- The check says which program writes the frames, not that the owner agreed. Software
  running as the owner can still start the real `remotedisplayd` with its own settings
  and have it feed the camera; the owner's switch is a user-level command too
  (decision 0009).
- The second check finds the client by pid, since CoreMediaIO gives the extension no
  audit token. It sees whatever process holds that pid when it runs.
- Until an admin allows the extension, the engine reports the camera as `not-installed`:
  it only sees whether the device exists, so it can't tell "not approved yet" from
  "not installed". The Setup row tells the owner which one it is.
- **Not verified on the build Mac, which has no Apple Developer team.** Each needs a
  signed build:
  - activation, the approval step, and the state macOS reports;
  - whether the sink check accepts `remotedisplayd`. The extension runs sandboxed, as
    its own role user. If that stops it from reading the client's code, it refuses every
    feeder, and `log stream --predicate 'subsystem == "app.remotedisplay.server.camera"'`
    shows why.
- An ad-hoc stand-in for the signed path (`SIGN_ID=-` with placeholder profiles) builds
  the layout, signatures and entitlements as described. `codesign --verify` then fails
  on `remotedisplayd`, whose designated requirement needs an Apple certificate. The
  Makefile before this change fails the same way.
