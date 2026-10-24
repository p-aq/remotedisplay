# 0010. One entitlements file per binary; extension signed first

- **Status:** Accepted, 2026-10-24 (review findings H-2, H-3; PR #16)
- **Original design:** Departs from the spec, which added the install entitlement to
  the app's entitlements. Follows `server-mac/Makefile`: stable identity, explicit
  designated requirement, Developer ID with Apple Development as fallback.

## Context

The Makefile signs `remotedisplayd`, the app executable and the bundle with the same
identifier and the same `Entitlements.plist`. The system-extension install entitlement
is restricted: a binary that claims it without a matching provisioning profile is
killed at launch, and each profile matches only one kind of certificate. macOS finds
system extensions by bundle identifier.

## Decision

- `remotedisplayd` keeps today's `Entitlements.plist`, unchanged.
- The app gets its own file with the install entitlement and the app group; the
  extension gets its own with the sandbox and the app group.
- The extension bundle is `app.remotedisplay.server.camera.systemextension`; users see
  "Remote Display Camera", the device name.
- Sign the extension first, on its own, then `remotedisplayd`, then the app, without
  `--deep`. Embed the profile that matches the chosen identity; a build without one
  leaves the extension out and says so in Setup.

## Consequences

- Ad-hoc and contributor builds keep working, without the camera.
- Existing Screen Recording and Accessibility grants survive, since the designated
  requirement doesn't change.
- Release builds need two more provisioning profiles.
