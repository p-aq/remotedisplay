# engine — the engine and how it syncs with upstream

`engine/rustdesk/` is a **snapshot** of [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk)
(tag in [`BASELINE`](BASELINE)) plus **our changes** applied on top. There is no fork
branch and no submodule: the model is *pristine snapshot → re-apply our diff*.

## Commands

```sh
bash engine/check.sh            # is there a newer upstream release than BASELINE?
bash engine/check.sh 1.5.0      # dry-run: would our diff re-apply cleanly on 1.5.0? (touches nothing)
bash engine/diff.sh --stat      # audit WHAT is ours (full diff vs upstream)
bash engine/diff.sh > ours.patch  # export; re-apply with git apply --directory=engine/rustdesk
bash engine/update.sh 1.5.0     # update the engine to a new tag
```

`update.sh`: (1) extracts our complete diff against the baseline, (2) commits the
pristine snapshot of the new tag (`git read-tree`: exact blobs and modes, which matters
on Windows), (3) re-applies our diff with a 3-way merge in the index — where upstream
touched the same lines, conflicts are left marked — and (4) updates `BASELINE` and
records the run in the table below. You make the final commit after reviewing and
building. `check.sh <tag>` runs steps 1–3 in a temporary index, so you can see the
conflicts before touching anything.

Self-test of the mechanism: updating to the SAME tag must rebuild `engine/rustdesk/`
identically (diff 0). Run it in a clean clone:
`git clone . /tmp/x && cd /tmp/x && bash engine/update.sh $(cat engine/BASELINE)` and then
`git diff --cached --quiet <original HEAD> -- engine/rustdesk`.

### `libs/hbb_common` (a submodule upstream, vendored here)

Upstream ships `libs/hbb_common` as a submodule of
[rustdesk/hbb_common](https://github.com/rustdesk/hbb_common). Here it is expanded into
the tree and `.gitmodules` is deliberately dropped. Its baseline is **never written by
hand**: it is the commit the tag's gitlink points to (`git ls-tree <tag> libs/hbb_common`),
and `engine/lib.sh` fetches it by SHA from the hbb_common repo (pinned under
`refs/hbb_common/<sha>`). `diff.sh` diffs hbb_common against that commit (with the
`libs/hbb_common/` path prefix, so the patch stays a single file) and `update.sh`
expands the NEW tag's hbb_common in place of the gitlink before re-applying our changes.
Without this, an update would leave our old hbb_common underneath a new engine.

### `libs/cpal` (a git dependency upstream, vendored here)

Upstream's `Cargo.toml` takes cpal from the `osx-screencapturekit` branch of
[rustdesk-org/cpal](https://github.com/rustdesk-org/cpal), and its `Cargo.lock` pins the
commit. Here that commit is expanded at `libs/cpal` and `Cargo.toml` takes cpal from it,
so our changes to cpal can be carried
([decision 0022](../docs/architecture/decisions/0022-vendored-cpal-excludes-own-audio.md),
[decision 0025](../docs/architecture/decisions/0025-cpal-buffer-range-from-the-device.md)).
It works as hbb_common does. Its baseline is **never written by hand**: it is the commit
the tag's `Cargo.lock` pins (`cpal_commit_of`), fetched by SHA and pinned under
`refs/cpal/<sha>`. `diff.sh` and `check.sh` diff `libs/cpal` against it, and `update.sh`
expands the new tag's commit there before re-applying our changes. `libs/cpal` is in the
workspace's `exclude`, so its dev-dependencies stay out of `Cargo.lock`.

### Files upstream force-adds against its own `.gitignore`

Upstream's `.gitignore` ignores `*png`/`*svg` (and `.vscode`), yet upstream tracks them
anyway (the icons in `res/`, the SVGs in `flutter/assets`, Android/iOS mipmaps,
`fastlane/`). When vendoring they must be added with `git add -f`; if they are missing, a
fresh clone does not build (`src/tray.rs` does `include_bytes!` on
`res/mac-tray-dark-x2.png`) and the engine's widgets cannot find their SVGs. The
generated bridge (`src/bridge_generated*.rs`, `flutter/lib/generated_bridge*.dart`) is
NOT committed, as upstream: generate it with `flutter_rust_bridge_codegen` 1.80.1 (see
`tools/README.md`).

## What is ours (delta summary)

`bash engine/diff.sh --stat` as of 2026-09-03: **41 files (+3706/−195) on top of upstream
1.4.9** plus `libs/hbb_common/src/config.rs` (+16/−4) on top of hbb_common@7e1c392.
Everything else in the diff (`.gitmodules` and the hbb_common gitlink deleted) is the
vendoring itself.

| Area | What |
|---|---|
| `src/` | serverless (rendezvous → 127.0.0.1), headless CM `--cm-no-ui`, active LAN + Tailscale discovery (`lan.rs`: pong keeps the host's engine id, advertises its Tailscale addresses, per-run tally for the client), host identity in the login response (`server/connection.rs`: `machine_id` + `addrs`) and its filing under every advertised address on the client (`client.rs` `spread_identity`), `load_lan_peers` event with the discovery tally (`flutter_ffi.rs`), no tray in non-flutter builds, no chat / update check |
| `src/platform/macos.mm`, `src/virtual_display_manager.rs`, `src/server/display_service.rs` | dynamic virtual displays on macOS (in-process CGVirtualDisplay, dynamic main, turning physical displays off/on, mirrored-physical mode guard, display topology hash) |
| `src/core_main.rs`, `src/server.rs`, `src/server/device_forward.rs` | the owner's switch for camera and microphone forwarding: `--set-device-forward on\|off`, `device_forward` in `remotedisplay-perms.json`, and who sends in `remotedisplay-forwarding.json` (`HOOKS.md` E3) |
| `src/server/connection.rs`, `src/server/device_forward.rs` | the host side of forwarding: capabilities, answering requests, one sender per device, `CameraFrame`s to the sink, a microphone forward's audio to the virtual mic, `DeviceStatus`, stopping on the owner's switch (`HOOKS.md` E7) |
| `src/server/connection.rs`, `src/server/connection/audio_gate.rs` | the host plays a controller's audio only during an accepted voice call or microphone forward, independent of `disable_audio` (`HOOKS.md` E2) |
| `src/server/audio_service.rs`, `src/server/audio_service/host_sound.rs` | with `screencapturekit`, host sound never falls back to an input device, and the login response says whether it can come at all (`rd_host_sound`) (`HOOKS.md` E1); the Phase 3 capture tests, `#[ignore]`d, run by `docs/tests/system-sound/` |
| `Cargo.toml`, `Cargo.lock`, `libs/cpal` (vendored, diffed against its pinned commit) | cpal from `libs/cpal`, outside the workspace; its ScreenCaptureKit capture leaves out the process's own audio, so a forwarded microphone doesn't go back to its controller (`HOOKS.md` E11); its CoreAudio host reads a device's buffer sizes from the device, so every output has configs and listing inputs doesn't wait on the microphone prompt (E13) |
| `src/platform/macos_mic_sink.mm`, `src/platform/macos_mic_sink.rs`, `src/server/device_forward/mic.rs` (and `build.rs`, `src/platform/mod.rs`, `src/server/connection.rs`) | the host's microphone path: decode, jitter buffer, Remote Display Microphone's feeder (`HOOKS.md` E10); its device test, `#[ignore]`d, runs from `docs/tests/virtual-mic/` |
| `src/client.rs`, `src/client/jitter.rs` | received audio, such as a host's sound, plays through the spec's jitter buffer instead of upstream's `AudioBuffer`, which is removed (`HOOKS.md` E14) |
| `src/client.rs`, `src/client/io_loop.rs`, `src/client/device_forward.rs` | the controller's camera and microphone senders: request, `CameraFrame`s or audio once accepted, `CameraControl`, their own queues into the io loop, ending the forward when the device goes away (`HOOKS.md` E6) |
| `src/client/device_forward/mic.rs`, `src/platform/macos_mic_capture.mm`, `src/platform/macos_mic_capture.rs` (and `build.rs`, `src/platform/mod.rs`) | the controller's microphone capture for a forward and macOS's microphone access (`HOOKS.md` E12) |
| `src/ui_session_interface.rs`, `src/flutter.rs`, `src/flutter_ffi.rs`, `src/client/io_loop.rs`, `src/client/device_forward.rs`, `flutter/lib/models/model.dart` | the Devices menu: the forward's state as the `rd_device_forward` session event, the menu's FFI calls (`HOOKS.md` E9 and #3) |
| `src/platform/macos_camera_sink.mm`, `src/platform/macos_camera_sink.rs` (and `build.rs`, `src/platform/mod.rs`) | the host's camera path: decode, letterbox, Remote Display Camera's sink (`HOOKS.md` E8); its fuzz pass runs in `docs/tests/camera-sink/` |
| `build.rs`, `src/platform/mod.rs`, `src/core_main.rs`, `src/platform/macos_camera_capture.mm`, `src/platform/macos_camera_capture.rs` | the controller's camera: capture, VideoToolbox encode, H.264 Annex B out, a camera unplugged mid-capture, and the `--camera-test-pattern` test card (`HOOKS.md` E5); the camera tests, `#[ignore]`d, run by `docs/tests/camera-capture/` |
| `libs/hbb_common/protos/message.proto`, `tests/device_forward_messages.rs` | the camera and microphone forwarding messages at `Message.union` 200–204, in the block Remote Display reserves (200–219), and their tests (`HOOKS.md` E4) |
| `libs/scrap` | mirrored-display filter on macOS (`CGDisplayMirrorsDisplay`); a stopped stream is an error, not `WouldBlock` |
| `libs/hbb_common` | serverless defaults in `config.rs`; `machine_id` in `DiscoveryPeer`/`PeerInfoSerde` (kept before the maps: confy stores with toml 0.5, which rejects a value after a table) |
| `libs/enigo` | macOS input tweaks |
| `flutter/` | hooks for `client/` (see `HOOKS.md`): `showToolbar`/`keyHelpHorizontal`, mobile keyboard focus, cursor crossing to an external display, etc. |
| `res/`, `fastlane/` | assets upstream force-adds against its `.gitignore` (here too, with `git add -f`) |

## Sync history

| Date | Change | Result |
|---|---|---|
| 2026-08-18 | initial snapshot of upstream **1.4.9** + serverless patches | fork is born |
| 2026-08-19 | self-test: update 1.4.9 → 1.4.9 | ✓ identical (diff 0, 93 files re-applied) |
| 2026-08-19 | self-test of the layout sync: 1.4.9 → 1.4.9 | ✓ mechanism verified |
| 2026-09-03 | snapshot repair on 1.4.9: 123 upstream files that were missing (assets force-added against `.gitignore`, `.gitattributes`, `CLAUDE.md`), 28 `+x` bits lost in the export; `tools/patches/` removed (single source of truth = `diff.sh`); hbb_common baseline derived from the tag (`lib.sh`); `check.sh` added | ✓ self-test in a clean clone: 1.4.9 → 1.4.9 identical (193 files re-applied, 0 conflicts) |
