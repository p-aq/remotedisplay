# 0011. The camera extension owns the placeholder and drains the sink

- **Status:** Accepted, 2026-10-24 (review findings H-4, H-5, H-6; PR #16)
- **Original design:** Extends the spec's extension ("moves each buffer from sink to
  source and shows the placeholder card while the sink is idle"). Keeps its rule that
  the extension stays thin: no decoding, no networking.

## Context

- If the feeder (`remotedisplayd`) crashes, nothing pushes a placeholder, and apps
  would show the last frame.
- A controller can turn the camera on before any app opens Remote Display Camera; if
  nothing consumes the sink, the feeder's queue fills and stalls.
- The extension runs as `_cmiodalassistants`, not the console user, so an app-group
  container or shared defaults can't carry data between it and the feeder.

## Decision

- The extension switches its source to the placeholder card, at a low frame rate, after
  500 ms without a sink buffer.
- It consumes the sink whenever the sink is started, whether or not any app is reading,
  and discards what nobody reads.
- Everything between feeder and extension travels through the sink stream (plus custom
  CoreMediaIO properties if ever needed). The app group is only for the mach service
  name.
- The extension validates every sink buffer's size and pixel format and drops
  mismatches.

## Consequences

- The disconnect and crash tests both expect the card within 1 s.
- The feeder can be dumb: push frames, drop when the queue is full.
