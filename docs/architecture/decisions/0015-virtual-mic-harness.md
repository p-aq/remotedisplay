# 0015. Virtual-mic harness: BlackHole configured, not modified; one engine-side module for both options

- **Status:** Accepted for Phase 0, 2026-10-24. Phase 2 decides how the driver source is
  kept.
- **Original design:** Extends the spec's Option A ("adapted from BlackHole"): no
  adaptation is needed, only build constants. Follows decision 0014 for layout,
  languages and build. Departs, for Phase 0 only, from how the repo keeps third-party
  code: the engine is vendored (`engine/BASELINE`, `engine/update.sh`); the driver
  source is fetched at a pinned commit instead.

## Context

- BlackHole v0.7.2's compile-time constants already describe decision 0013's layout: a
  visible input-only device and a hidden output-only twin sharing one buffer. Upstream
  documents that pairing.
- Copying BlackHole (GPL-3.0) into the repo for a measurement would add 4,600 lines
  that Phase 0 never changes.
- Both options need the same engine-side job: play audio, supplied by the future jitter
  buffer, into something that shows up as Remote Display Microphone.

## Decision

- The harness lives in `docs/tests/virtual-mic/`, shaped like the camera harness.
- The Makefile clones BlackHole at tag v0.7.2, refuses to build unless it is commit
  `561d934`, and compiles it with `clang -bundle` and our constants: names, bundle ID,
  2 channels, 48 kHz only, never a default device. The bundle uses its own CFPlugIn
  factory UUID, so it can sit next to an installed BlackHole.
- `mic_sink.mm` implements both options behind one `extern "C"` API that takes a render
  callback, called once per I/O cycle. Phase 2 keeps whichever option wins and plugs the
  jitter buffer into the callback.

## Consequences

- Building Option A needs network access the first time.
- If Option A wins, Phase 2 either vendors the driver the way the engine is vendored
  (with a baseline and an update script) or keeps the pinned fetch in
  `server-mac/Makefile`; that choice gets its own record.
- Nothing in the harness depends on which option wins.
