# 0033. Who may feed Remote Display Camera, now that the extension can't ask macOS

- **Status:** Accepted, 2026-11-21 (issue #2): option 2 for who feeds the camera, and
  option A for a camera that appears after the engine started; see "Outcome" below.
  Proposed 2026-11-20, after the camera session of 2026-11-19.
- **Original design:** Changes decision 0019's rule "Only `remotedisplayd` may feed the
  sink", whose two checks don't work on a real Mac. The goal stays the same: no other
  program puts frames into a meeting through Remote Display Camera.

## Context

The camera session on the Mac mini (macOS 27.2.1, signed build, results under "Run on
2026-11-19" in `docs/tests/live-session/README.md`) found that the extension refused
`remotedisplayd` every time, so the camera never worked until a test build let any feeder
in. Decision 0019's two checks each fail:

- **CoreMediaIO's signing identifier is "unknown".** `CMIOExtensionClient.signingID` (the
  SDK says only "the client's signing identifier") was `unknown` for `remotedisplayd`
  started by launchd, and for every test feeder tried overnight (`sink_probe.m` in
  `docs/tests/live-session/harness/`):
  - ad-hoc signed;
  - signed by the team, hardened runtime;
  - the same, with an embedded `Info.plist`;
  - an app bundle opened through Launch Services;
  - an ad-hoc program claiming `app.remotedisplay.server`.

  So it can't tell feeders apart, ours included.
- **The extension may not look up another process's code.** `SecCodeCopyGuestWithAttributes`
  by pid fails with EPERM (100001) for `remotedisplayd` and EACCES (100013) for the test
  feeders. The extension runs sandboxed as the `_cmiodalassistants` role user. A program
  under the plain App Sandbox, run as the console user, *can* do the same lookup, read
  another process's path with `proc_pidpath`, and check `/Applications/Remote Display
  Server.app/Contents/MacOS/remotedisplayd` on disk against the team's requirement. So the
  refusal comes from the camera extension's own environment, and only an installed
  extension can say what it allows.
- **Apple offers nothing else.** `CMIOExtensionClient` has only `clientID`, `signingID` and
  `pid`; no audit token. On the developer forums Apple's DTS recommends custom properties
  for control and a sink stream for video, and says programs in a user session can't
  reach the extension's own endpoints (thread 706184). No answer covers restricting who
  feeds a sink.
- **OBS Virtual Camera doesn't check.** Its sink's `authorizedToStartStream` stores the
  client and returns `true`.
- **What's at stake:** a program already running on the host, as any user, could put its
  own frames into a call in place of the controller's camera, while Remote Display's menu
  shows nothing. Installing a camera extension needs an admin's approval, so ours would
  be the way in.

## Options

1. **Check the feeder's program on disk.** When the sandbox refuses the lookup by pid, find
   the program the client runs from (`proc_pidpath`) and check that file against the same
   designated requirement: identifier `app.remotedisplay.server`, signed by the team. It
   keeps decision 0019's guarantee for practical purposes. The hardened runtime and
   library validation stop other code from running inside a genuine `remotedisplayd`. A
   copy of the genuine program would pass, but it only ever feeds what a connected
   controller sends. **Unknown:** whether the extension's environment allows
   `proc_pidpath` and reading `/Applications`. Built as version 20 on branch
   `phase1/camera-feeder-check`, not yet installed. Small change.
2. **Any feeder, one at a time, and the host shows it.** Accept any feeder, as OBS does,
   but keep the sink for the first one until it stops. The extension publishes the
   feeder's pid as a custom property. The app compares it with its own engine and the
   menu says *"Another program is feeding Remote Display Camera"* when they differ. It
   doesn't stop an intruder that gets in first, but it shows one. Medium change: new
   state in the extension (who holds the sink, and letting go when that client dies)
   and a property the app reads.
3. **A broker daemon.** A small root LaunchDaemon (`SMAppService.daemon`, one admin
   approval) that both the engine and the extension reach over XPC, each checked by code
   signing requirement. The broker tells the extension the verified engine's pid. It's
   the strongest option, but it adds a privileged process, another approval in Setup, and
   the most code to keep. Large change.
4. **Any feeder, no check** (OBS's choice). Smallest change. It drops the goal of decision 0019.

## Recommendation

Try **option 1** first: install version 20 in the next session and watch the extension's
log (`Accepted sink client … /Applications/…/remotedisplayd`, or `Refused …` with the
reason). Then run the test feeders against it:

- `p5`, the ad-hoc program claiming our identifier, must be refused;
- `p2`, signed by the team under another identifier, must be refused.

If the extension's environment refuses `proc_pidpath` or the file read, fall back to
**option 2**, and record the remaining risk in the spec's security notes. Keep option 3 for
a release, if a review of the threat says it's needed.

**Option 2, built for the same session (branch `phase1/camera-one-feeder`):**
- The extension accepts any feeder that CoreMediaIO doesn't name as another program. It
  still runs the code check, but only logs *Verified* or *not verified*.
- It keeps the sink for that feeder until the feeder stops, disconnects or exits. Another
  feeder meanwhile is refused (`… is feeding the camera`), so the engine's request ends as
  `sink-failed`.
- The device publishes the feeder's pid as the custom property `4cc_feed_glob_0000`, as a
  string, empty when none.
- Once the camera is installed, the server app reads that property every 2 s. When the pid
  isn't the engine's, the Camera row and the menu say *"Another program, NAME, is feeding
  Remote Display Camera"*. **Since 2026-11-21** both add *· quit it to free the camera*.
- The spec's security table records the remaining risk.

The test: hold the sink with the probe (`./p1 30`). The app should name it, and the
controller's camera should be refused until the probe stops. Then the engine's own forward
should show no warning. Without camera access (option B), the app may not see the device
after an extension update until it restarts, the same limit as the engine's.

## Outcome (camera session, 2026-11-21)

- **Option 1 doesn't work.** The installed extension gets each feeder's path, but its
  sandbox may not read the file: EACCES (100013) in the user's temp folder, EPERM (100001)
  under `/Applications`. A test feeder signed by the team as `app.remotedisplay.server`, the
  requirement itself, was refused the same way, and so was `remotedisplayd`.
- **Option 2 is chosen.** It passed all three checks:
  - the engine fed the camera, with no warning;
  - a second feeder was refused while the engine fed it;
  - a feeder that came first was named in the server app's menu, and the controller's
    camera was refused until it stopped.
- **Option B didn't help, so option A is chosen** (next section). With camera access
  granted, macOS asked TCC about the running engine when the updated device appeared, and
  the answer was *allowed*. The engine still never got the device. Neither did Photo Booth
  or Safari, both allowed, while freshly started programs saw it. A restarted engine did.
  So the app restarts the engine once Remote Display Camera is new: 3 s after macOS
  finishes replacing it, and after an admin allows it while the engine runs. After an
  update, Setup's Camera row and the menu say *"Updated · reopen apps that were using Remote
  Display Camera"* until the owner clicks OK (Paolo's request). No camera permission and no
  Setup step are added.

## Also found: the engine misses a camera that appears after it starts using CoreMediaIO

Not the same question, but the same session, and it decides issue #7.

- **What happened:** after the extension went from version 18 to 19, the engine never saw
  Remote Display Camera: every controller was told `not-installed`, until the engine
  restarted. A fresh process listed the camera and its sink all along.
- **Why, from the logs:** when a camera device is added, CoreMediaIO's
  `registerassistantservice` asks TCC whether each process *already using CoreMediaIO* may
  use the camera, and tells only those that may. At the 18 → 19 swap the controller
  reconnected at once, so the engine had already asked for Remote Display Camera's status.
  When version 19's device appeared a second later, TCC was asked about `remotedisplayd`
  and said "requires entitlement com.apple.security.device.camera but it is missing". The
  engine was never told about the device. At the 17 → 18 swap nothing had connected yet, the
  engine first touched CoreMediaIO after the device was up, and saw it. In both swaps TCC
  was also asked about Spotify, another process already using CoreMediaIO.
- **When it bites:**
  - after every extension update (decision 0032), if a controller is connected or
    reconnects quickly;
  - at login, if a controller connects before the extension's device is up (test 20 will
    show whether that happens).
- **Issue #7's answer, then:** feeding the sink needs no Camera permission, but *seeing a
  camera that appears later* does.
- **Options:**
  - **A. Restart the engine when the device appears.** The app watches for Remote Display
    Camera (a fresh check, like `cmio_list`, or its own CoreMediaIO listener, since the app
    *is* told). It restarts the engine when the camera shows up and the engine reports
    `not-installed`. No new permission, but sessions drop at every update, and the app needs
    a reliable trigger.
  - **B. Give the engine Camera access.** It gets `com.apple.security.device.camera` (build B
    already has it), and the app asks for camera access once in Setup. TCC keys the answer
    on the identifier and requirement that the app and `remotedisplayd` share, so the
    engine should inherit it; to be tested. The user sees a camera prompt for a server app,
    which needs explaining in Setup ("to see Remote Display Camera").
  - **C. Keep the engine off CoreMediaIO until the device is there.** The sink status comes
    from a short-lived helper process, so the engine's first CoreMediaIO call happens after
    the device is up. That fixes login but not updates, so it would still need A for
    updates.

  **Recommendation:** test B first, with build B plus a Setup button that asks for access.
  If the engine then sees a camera added later, B is the cleanest, and it's what
  CoreMediaIO expects. Otherwise A. (Tested 2026-11-21: B didn't help, so A; see
  "Outcome".)
