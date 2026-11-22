# 0034. The engine runs from Contents/Helpers, so macOS doesn't take it for the app

- **Status:** Proposed, 2026-11-21, after the camera session of 2026-11-21. For Paolo.
- **Original design:** Changes where the server app bundles `remotedisplayd`:
  `Contents/MacOS` since Remote Display 1.0, now `Contents/Helpers`. It keeps the rule
  that the app and the engine share one code identity, so one grant of Screen Recording
  and Accessibility covers both (`Permissions.swift`).

## Context

`remotedisplayd` sits beside the app in `Contents/MacOS` and is signed with the app's
identifier. It runs AppKit's event loop (`MacRunHeadlessAppLoop`), so Launch Services
registers it as the app itself. `lsappinfo` lists it as "Remote Display Server"
(`bundleID="app.remotedisplay.server"`, `UIElement`). Two things follow:

- **Opening the app does nothing while the engine runs without it.** Finder, the Dock and
  `open` just bring the engine forward, and the app doesn't start (camera session,
  2026-11-21: `open` failed, `open -n` worked). The engine runs without the app whenever the
  app has crashed, been killed, or been quit while the service stays on (the LaunchAgent
  keeps it), and at login before the app's login item. The owner then can't get the app back.
- **A quit sent by Apple event reaches the engine, not the app.** `osascript -e 'quit app
  "Remote Display Server"'` quit the engine, and the app's watchdog started a new one
  (2026-11-19). Logout's quit goes the same way.

Decision 0033 option B, now dropped, counted on the engine keeping the app's identity. That
no longer holds anything back.

## Options

Tried with `docs/tests/live-session/harness/ls-probe/run.sh`: a throwaway bundle with an
accessory app and a headless engine like ours, the engine started through launchd.

1. **Move the engine to `Contents/Helpers`.** Launch Services no longer takes it for the
   app:
   - opening the bundle started the app;
   - a scripted quit reached the app, and the engine kept running.

   `tccd` still checked the bundle's identity for the engine's Screen Recording status
   (`type: 0` at the app's path), the same as from `Contents/MacOS`. So the shared grant
   should hold. `Contents/Helpers` is the standard place for nested helper tools, signed
   on their own like today.
2. **Keep it in `Contents/MacOS`; the engine answers open and ignores quit.** Once its
   handlers are installed after AppKit's launch, it can start the app on *open*. But:
   - it got both *open* and *reopen* and started the app twice, so it would have to check;
   - a scripted quit still never reaches the app;
   - it needs engine code, and Launch Services still lists the engine as the app.
3. **Give the engine its own identity** (a helper bundle with another identifier). Clean
   for Launch Services, but the engine would need its own Screen Recording and
   Accessibility grants, two more prompts in Setup. Rejected for that.

## Recommendation

**Option 1.** What changes:

- **`server-mac/Makefile`:** copy and sign `remotedisplayd` into `Contents/Helpers`.
- **`ServerController.swift`:**
  - `enginePath` and the `pgrep` patterns for the engine and its helpers move to the new
    place;
  - the patterns also match the old one for one release, so the first launch after an
    update can stop an engine still running from `Contents/MacOS`;
  - the app rewrites the LaunchAgent's plist, which names the engine's path, then restarts
    the engine.
- **The live-session `host.sh`** already removes by the bundle's path, so it needs nothing.

**To verify** with a signed build on the Mac mini:
- Screen Recording and Accessibility, granted once in Setup, still cover the engine;
- opening the app while the engine runs starts the app;
- a scripted quit quits the app, and its own Quit still stops the engine;
- an update from a build with the engine in `Contents/MacOS` moves it over.

## Consequences

- The owner can always get the app back, and logout or a script no longer quits the engine
  behind the app's back.
- Upstream RustDesk's own install and update code names `Contents/MacOS` (`platform/macos.rs`),
  but Remote Display's server mode doesn't use it.
