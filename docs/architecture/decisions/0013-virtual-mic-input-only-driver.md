# 0013. Virtual mic as an input-only driver fed by a hidden device

- **Status:** Accepted, 2026-10-24, on Phase 0's results (`docs/tests/virtual-mic/`).
  Proposed earlier the same day from review findings A-5, O-2, O-3, O-4 (PR #16).
  Answers issues #8 and #9; Zoom and Teams (test 8) are still to be confirmed. Amended
  by decision 0031: the device can be the default input.
- **Original design:** Extends the spec's Option A. The spec spiked both options and
  left the choice open; this leans towards A.

## Context

- Option A (a BlackHole-derived HAL plug-in) is known to work, but stock BlackHole puts
  input and output on one device. If it became the system output, all host sound,
  including the far end of the call, would go into the mic.
- Option B (a Core Audio tap plus aggregate device) needs nothing installed, but its tap
  mutes only while something reads it. Before Zoom opens the device, the mic audio plays
  from the host's speakers and the host's sound capture sends it back to the controller.
  Whether Zoom and Teams accept such a device is unknown.

## Decision

Use Option A for v1. Publish "Remote Display Microphone" as an input-only device that
can't become a default device, so it never appears under Sound › Output, and feed it
through a second, output-only device marked hidden (`kAudioDevicePropertyIsHidden`) that
`remotedisplayd` opens by UID. Install with an admin prompt and a coreaudiod restart in
the same step: `killall coreaudiod`, since `launchctl kickstart` is refused while SIP is
on.

Why A over B, now that both work (Phase 0):

- **The choice sticks.** A's device exists whether or not `remotedisplayd` runs, as the
  spec's user experience asks. B's device disappears with the process, so an engine
  restart would pull the mic out from under a call.
- **Latency.** A added no measurable offset (0.0 ms); B added 32 ms.
- **Fewer moving parts at run time.** A needs no tap, aggregate or second output stream
  while forwarding.

Option B stays documented as the fallback for a build that can't install a driver: it
needs no admin and showed no prompts, as long as it uses `CATapMuted` (never
`CATapMutedWhenTapped`).

## Consequences

- An admin password at install, like the camera extension's approval.
- GPL-3.0 driver code combined with AGPL-3.0, which section 13 allows.

## Phase 0 results (2026-10-24)

Details in `docs/tests/virtual-mic/`.

- BlackHole's own build constants give this layout with no code changes, and an
  ad-hoc-signed build loads.
- Option A: test signal bit-exact; input-only (2 in, 0 out); can't become a default
  device; the feeder is hidden; uninstalling restores the HAL folder.
- Option B's failure mode above happens with `CATapMutedWhenTapped` (heard at the
  speakers until something read the device) and not with `CATapMuted` (silent
  throughout, signal bit-exact).
- A tap-only aggregate is input-only, so Option B can't become a speaker either.
- Option B's device exists only while `remotedisplayd` runs.
