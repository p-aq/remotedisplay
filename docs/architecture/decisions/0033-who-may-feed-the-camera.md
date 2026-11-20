# 0033. Who may feed Remote Display Camera, now that the extension can't ask macOS

- **Status:** Proposed, 2026-11-20 (issue #2), after the camera session of 2026-11-19. Not
  yet chosen: the options and a recommendation are below, for Paolo.
- **Original design:** Changes decision 0019's rule "Only `remotedisplayd` may feed the
  sink", whose two checks don't work on a real Mac. The goal stays the same: no other
  program puts frames into a meeting through Remote Display Camera.

## Context

The camera session on the Mac mini (macOS 27.2.1, signed build, results in
`remotedisplay-signing/session/results.md`) found that the extension refused
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

## Also found: the engine misses a camera that appears after it starts

Not the same question, but the same session:

- **What happened:** when the extension was replaced while `remotedisplayd` was starting,
  CoreMediaIO's `registerassistantservice` checked the Camera permission for
  `remotedisplayd`. It logged that the service "requires entitlement
  com.apple.security.device.camera but it is missing". That engine never saw Remote
  Display Camera and told every controller it wasn't installed, until it restarted.
- **Where it matters:** at login, if the engine starts before the extension's device is
  up (test 20), and after every extension update (decision 0032).
- **Possible fixes:**
  - the app restarts the engine once an activation request finishes;
  - or `remotedisplayd` gets the camera entitlement and the Camera permission (issue #7),
    if a launchd agent can be given it at all.

  Test 20 and an update with the engine running will say which is needed.
