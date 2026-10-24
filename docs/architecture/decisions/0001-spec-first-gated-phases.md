# 0001. Spec first, delivered in gated phases

- **Status:** Accepted, 2026-10-23
- **Original design:** Follows the spec. Follows CONTRIBUTING.md ("measured, not assumed").

## Context

Camera forwarding into a Mac host depends on macOS behaviour nobody on the project has
measured yet: camera extensions fed by a background process, virtual audio devices,
system-extension signing. Building the engine and protocol changes first would risk
rework if one of those doesn't behave as expected.

## Decision

Work from a written spec (`docs/specs/camera-audio-forwarding.md`) and deliver it in
six phases, each with a gate that must pass before the next starts. Phase 0 measures
the risky macOS pieces in isolation. Phase 3 is independent and can ship at any point.
Work happens on `feature/camera-audio-forwarding` in the `p-aq/remotedisplay` fork;
each phase is a GitHub milestone with an issue.

## Consequences

- The spec is the reference for "the original design"; changes to it are commits with
  reasons, recorded here.
- No engine change lands before Phase 0's gate passes.
- Phases 1–3 together make v1.
