# 0013. Virtual mic as an input-only driver fed by a hidden device

- **Status:** Proposed, 2026-10-24 (review findings A-5, O-2, O-3, O-4; PR #16).
  Phase 0 decides (issues #8, #9).
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

Lean towards Option A for v1. Publish "Remote Display Microphone" as an input-only
device, so it never appears under Sound › Output, and feed it through a second,
output-only device marked hidden (`kAudioDevicePropertyIsHidden`) that `remotedisplayd`
opens by UID. Install with an admin prompt and a coreaudiod restart in the same step.
Phase 0 tests both options, including Option B's unmuted case, before this becomes
Accepted.

## Consequences

- An admin password at install, like the camera extension's approval.
- GPL-3.0 driver code combined with AGPL-3.0, which section 13 allows.

## Phase 0 notes (2026-10-24)

Not a decision yet; these shape it. Details in `docs/tests/virtual-mic/`.

- BlackHole's own build constants give this layout with no code changes.
- Option B's failure mode above belongs to `CATapMutedWhenTapped` only. The SDK also has
  `CATapMuted`, which never sends the process's audio to the hardware.
- A tap-only aggregate is input-only, so Option B can't become a speaker either.
- Option B's device exists only while `remotedisplayd` runs, which works against the
  spec's "the choice sticks" between sessions.
