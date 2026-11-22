# 0032. A new app version asks macOS to replace the installed camera extension

- **Status:** Accepted, 2026-11-14 (issue #2)
- **Original design:** Follows the spec's Packaging › Updates, "A new app version updates
  the extension", and says how. Extends decision 0019, which gave the extension the app's
  version numbers "so a new app version updates it" but never asked macOS to.

## Context

- **macOS replaces a system extension only on request.** The copy in use lives in
  `/Library/SystemExtensions`. A newer one inside an updated app does nothing until the
  app submits an activation request. macOS then compares the versions and, when they
  differ, asks the request's delegate whether to replace.
- **The app only asked from *Install…*,** which Setup shows when nothing is installed.
  The state check reported "installed" for any enabled version. So an updated app kept
  the old extension, with a green tick on the Camera row. A review of PR #34 found it.
- **It matters at once:** the fix in PR #48 lives in the extension. A Mac that had
  installed an earlier build would have kept refusing every forwarded frame.
- **The microphone's driver** offers *Update…* instead (decision 0027), because copying
  it needs an admin password each time. Replacing an extension from the same team needs
  no new approval.

## Decision

**Since 2026-11-21** a finished replacement also restarts the engine, 3 s later, and Setup's
Camera row and the menu tell the owner to reopen apps that were using Remote Display Camera,
until they click OK. Running programs, the engine included, didn't get the new device
([decision 0033](0033-who-may-feed-the-camera.md), option A).

- **Compare on every state check.** The check reads the version of the extension in use
  (`bundleShortVersion`, `bundleVersion`) and the bundled one's `Info.plist`. Any
  difference counts, older or newer: the app's own extension is the one that matches its
  `remotedisplayd`.
- **Ask once per launch.** On a difference, the app submits the activation request
  itself, and answers `.replace` as before. If macOS refuses, the installed version stays
  in use and the Camera row shows macOS's message; the app doesn't ask again until it
  next starts.
- **The row** shows "Waiting for macOS…" during the request, as for an install. If macOS
  wants an admin's approval again, it shows the approval step.
- **A failed request goes back to the state before it,** with macOS's message, where it
  used to show *Install…* for a moment whatever was installed. The message clears when
  the state next changes, as when an admin allows an earlier request. **Since 2026-11-21**
  the row says what to do in a sentence of its own, and macOS's message goes to the log
  (decision 0019).
- **`CameraExtension.evaluate`** holds the comparison, apart from macOS's types, so it
  can be tested.

## Consequences

- An app update reaches the camera without Remove and Install…. Apps that had the camera
  open may keep the old one until they relaunch (spec, Packaging).
- A build with the same version numbers as the installed extension isn't an update, even
  if its code differs: macOS wouldn't replace it either. A test build that changes the
  extension needs another `CFBundleVersion`; `make VERSION=…` sets the extension's.
- A failed removal's message stays on the row until the next request or state change.
- Tested: `make update-test` in `docs/tests/camera-extension/harness` checks the
  comparison in ten cases. **Not yet run:** the replacement itself, which needs an
  installed extension (the live session's test 21).
