# 0022. cpal is vendored into the engine, and host sound leaves out remotedisplayd's own audio

- **Status:** Accepted, 2026-10-29 (issues #3 and #4)
- **Original design:** Extends the spec's Speakers ("turn on the existing ScreenCaptureKit
  path") with one change to that path, found while testing decision 0021. Follows how
  the repo keeps third-party engine code: vendored, as a pristine copy plus our diff
  (`engine/SYNC.md`, the way `libs/hbb_common` is kept). Departs from upstream, which
  takes cpal from a git branch.

## Context

- **The echo.** `remotedisplayd` captures the host's sound with cpal's ScreenCaptureKit
  host and, since decision 0021, also plays a controller's microphone into Remote Display
  Microphone. cpal sets `excludesCurrentProcessAudio` to false, and ScreenCaptureKit
  captures by process, whatever the output device. So the microphone went back to the
  controller that sent it: `make own-mic` in `docs/tests/system-sound/harness` heard 100
  of 100 tone windows. A controller with *Play the Mac's sound here* on would hear its
  own voice about 50 ms late. Voice calls don't have this problem: during one, the host
  sends its microphone, not ScreenCaptureKit's capture (`host_sound.rs`).
- **The fix is one line.** With `excludesCurrentProcessAudio` true, in a scratch copy of
  cpal, `make own-mic` passed (silence) and `make hears` still did (100 of 100). Sound
  from other processes still goes out. `remotedisplayd` plays nothing a controller should
  hear.
- **Where cpal comes from.** Upstream's `Cargo.toml` takes cpal from the
  `osx-screencapturekit` branch of rustdesk-org/cpal, and its `Cargo.lock` pins commit
  `6b374bc`. That code is outside the engine snapshot, so the snapshot-plus-diff model
  can't carry a change to it.
- **Two ways to change it:** vendor cpal into the engine, or fork it on GitHub (p-aq/cpal)
  and point `Cargo.toml` at the fork, as RustDesk itself does with rustdesk-org/cpal.

## Decision

- **Vendor it.** `engine/rustdesk/libs/cpal/` is rustdesk-org/cpal at the commit the
  baseline tag's `Cargo.lock` pins, expanded the way `libs/hbb_common` is. The import is a
  commit of its own, with none of our changes.
- **Its baseline is never written by hand.** `engine/lib.sh` reads it from the tag's
  `Cargo.lock` (`cpal_commit_of`) and fetches it by SHA, pinned under `refs/cpal/<sha>`.
  `diff.sh` and `check.sh` diff `libs/cpal` against that commit, and `update.sh` expands
  the new tag's commit there before re-applying our diff. So our diff stays the one line,
  not the library.
- **The build.** `Cargo.toml` takes cpal from `libs/cpal`. `libs/cpal` is in the
  workspace's `exclude`, so it stays a dependency, not a member. As a member, its
  dev-dependencies (`clap`, `hound`, a newer `ringbuf`) would be resolved into
  `Cargo.lock` and have to be downloaded. `Cargo.lock` changes by one line: cpal's
  `source`.
- **The change** (`libs/cpal/src/host/screencapturekit/mod.rs`, marked `remotedisplay:`):
  `set_excludes_current_process_audio(true)`.
- **Why not a fork.** Everything stays in this repo and builds without fetching cpal. The
  fix is reviewed in the stack next to the test that shows it, and the sync scripts keep
  working as they do for the rest of the engine. A fork would be a second public
  repository to keep in step by hand.

## Consequences

- About 16,000 lines of rustdesk-org/cpal (Apache-2.0) are in the repo. They count as
  upstream, not ours, in `diff.sh`.
- `engine/update.sh` now also follows upstream's cpal pin. If a release stops taking cpal
  from git, `cpal_commit_of` finds no pin and the scripts stop with an error, to be
  decided then.
- A controller no longer hears its own microphone.
- **Tested** with a scratch copy of the same commit and the same line (2026-10-29,
  `docs/tests/system-sound/`): `make own-mic` heard 0 tone windows, and `make hears` still
  heard 100 of 100. The vendored build has the same source.
- The change could go to rustdesk-org/cpal (issue #15). If upstream took it, the vendored
  copy could go.
