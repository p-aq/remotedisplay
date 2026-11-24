# 0034. The engine stays in Contents/MacOS and opens the app when macOS asks it to

- **Status:** Accepted, 2026-11-23 (Paolo): option 2; see "As built" below. To revisit if
  owners report trouble with it.
  - Proposed 2026-11-21, after the camera session of 2026-11-21.
  - Accepted the same day with option 1, the engine in `Contents/Helpers`.
  - Tried at the Macs on 2026-11-23: option 1 loses the shared Accessibility grant (below),
    so option 2 instead.
- **Original design:** The server app bundles `remotedisplayd` in `Contents/MacOS`, beside
  the app, as since Remote Display 1.0. The app and the engine share one code identity, so
  one grant of Screen Recording and Accessibility covers both (`Permissions.swift`).

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
  (2026-11-19, again 2026-11-23). Logout's quit goes the same way.

Decision 0033 option B, now dropped, counted on the engine keeping the app's identity. That
no longer holds anything back.

## Options

Tried with `docs/tests/live-session/harness/ls-probe/`: a throwaway bundle with an accessory
app and a headless engine like ours, the engine started through launchd.

1. **Move the engine to `Contents/Helpers`.** Launch Services no longer takes it for the
   app: opening the bundle started the app, and a scripted quit reached the app while the
   engine kept running. `tccd` still identifies the engine by the bundle for Screen
   Recording (`run.sh`: `type: 0` at the app's path).
   **But not for Accessibility.** At the Macs on 2026-11-23 the engine in `Contents/Helpers`
   reported Accessibility off while the app had it, and `accessibility.sh` shows why: from
   `Contents/MacOS` `tccd` files the engine's Accessibility under the bundle ID
   (`identifier_type=Bundle ID`); from `Contents/Helpers` under the engine's own path
   (`identifier_type=Path`), a client of its own. So the engine would need its own
   Accessibility grant, listed in System Settings as "remotedisplayd", on a fresh install as
   well as after an update. On the way the app's check for a new grant (a fresh
   `remotedisplayd --check-perms`, which macOS judges as the app because the app starts it)
   kept answering yes, and the app restarted the engine every 2 s.
2. **Keep it in `Contents/MacOS`; the engine opens the app.** The engine takes the open and
   reopen Apple events and starts the app, or, when the app runs, asks it to show its
   window. One grant still covers both. But:
   - open and reopen can both arrive for one open, so the engine must start the app once;
   - a scripted quit still reaches the engine, not the app;
   - it needs engine code, and Launch Services still lists the engine as the app.
3. **Give the engine its own identity** (a helper bundle with another identifier). Clean
   for Launch Services, but the engine would need its own Screen Recording and
   Accessibility grants, two more prompts in Setup. Rejected for that.

## Decision

**Option 2.** One Accessibility and Screen Recording grant for the app and the engine
matters more to the owner than a scripted quit reaching the app. Getting the app back when
it is opened was the real harm, and option 2 fixes it.

## As built

- `src/platform/macos.mm`, `MacRunHeadlessAppLoop` (ours): after AppKit's launch, which
  installs its own handlers, the engine handles the reopen, which Launch Services sends to
  it when the app is opened while the engine runs. Not the open: that is the engine's own
  launch, and handling it started the app at every engine start and login (found at the
  Mac mini, 2026-11-23).
  - If Remote Display Server's own program is running, the engine posts the distributed
    notification `app.remotedisplay.server.showWindow`; the app shows its window. A
    notification, not an Apple event to the app, which would need Automation permission.
  - Otherwise it starts the app as a new instance, or Launch Services would hand the open
    back to the engine. It starts it at most once in 10 s, so a second open before the app
    is up doesn't start a second app.
  - Only when the bundle's program is another binary than the engine, so a bare `rustdesk` or
    an app that is the engine itself doesn't change.
- `AppDelegate.swift` listens for that notification and shows the main window, as on reopen.
- The LaunchAgent's plist names the app in `AssociatedBundleIdentifiers`, so Login Items
  names Remote Display Server, not "remotedisplayd" (macOS's background-item notification
  should too).
- The live-session `host.sh` kills leftovers matching the whole bundle's `Contents/`.
- `ls-probe/accessibility.sh` records the Accessibility identity check.

**Verified** on the Mac mini, 2026-11-23 and 24, team-signed, without the camera extension:
- Screen Recording and Accessibility, granted once, cover the engine, with no restarts;
- the engine started alone by launchd, as at login with Open at Login off (a `launchctl
  bootstrap`, not a real login): the app doesn't start;
- with the engine alone, opening the app starts it once and shows its window; two opens in
  a row still start one app;
- with both running and the window closed, opening the app shows the window; closing it
  again leaves the app in the menu bar;
- a scripted quit ends the engine, which the app starts again, without showing the window;
- Login Items lists the LaunchAgent under Allow in the Background as Remote Display Server.

## Consequences

- The owner can always get the app back by opening it.
- A scripted quit, and logout's, still reach the engine. Logout ends it anyway; a script
  that quits the app has to quit the app's own process (`kill`, or the menu's Quit).
- Launch Services and Activity Monitor still list the engine as "Remote Display Server".
- If owners report trouble with this, option 1 comes back with its own Accessibility grant
  for the engine, or option 3.
