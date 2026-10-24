# 0014. The camera harness follows the repo's harness, engine and server-app patterns

- **Status:** Accepted for Phase 0, 2026-10-24. Phase 1 revisits the build part.
- **Original design:** Follows the spec's Phase 0 ("a standalone camera extension fed by
  a small command-line tool"). Departs from its packaging plan ("build the extension
  with xcodebuild from its own target") for now. Follows CONTRIBUTING.md
  (`docs/tests/<topic>/` with a harness), `src/platform/macos.mm` and
  `server-mac/Makefile`.

## Context

A first draft put the spike in a new top-level `spikes/` folder, all in Swift. That
would have started three patterns the repo doesn't have: a spikes folder, Swift on
the engine side, and throwaway code that Phase 1 rewrites. The build Mac also has only
the Command Line Tools, no Xcode.

## Decision

- The harness lives in `docs/tests/camera-extension/`, with a README in the shape of
  `docs/tests/vdisplay-vm/`: what was tested and the result, runtime findings, how to
  re-run.
- Each piece is written in the language of the place it moves to in Phase 1:
  - the extension and container app in Swift, like `server-mac/`;
  - the sink code in Objective-C++ with `extern "C"` `Mac…` functions, `-std=c++17`
    and no ARC, like `src/platform/macos.mm`, so it moves into the engine as is.
- It builds with `swiftc`, `clang++` and a Makefile that assembles and signs the
  bundles, like `server-mac/Makefile`, instead of an Xcode project. Signing follows
  decision 0010: the extension first, on its own, without `--deep`.

## Consequences

- Phase 0 code is a first draft of Phase 1 code, not a throwaway.
- No Xcode project to keep in sync. Provisioning profiles are passed to `make` by hand,
  since Xcode's automatic signing isn't used.
- Phase 1 decides whether `server-mac/Makefile` keeps building the extension this way
  or moves to `xcodebuild`; either way the result is recorded here or in a new
  decision.
