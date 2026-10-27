# HOOKS.md — client/ hooks inside the engine

Project rule: `client/` does NOT edit the engine except for **minimal,
backward-compatible hooks documented here**. On every upstream update
(`engine/update.sh`), this list is the only thing to review if there are conflicts
on the Flutter side.

| # | File (engine/rustdesk/) | What | Why |
|---|---|---|---|
| 1 | `flutter/lib/desktop/pages/remote_page.dart` | Optional `showToolbar = true` param on `RemotePage`; with `false` it doesn't mount the built-in `RemoteToolbar` | `client/` suppresses RustDesk's toolbar and overlays its own (`client/lib/session/session_toolbar.dart`). Default `true` ⇒ the engine's own app doesn't change at all |
| 2 | `flutter/lib/models/peer_model.dart` | `Peer.machineId` and `Peer.onlineKnown` from the event JSON (`machine_id`, `online`); `Peers._updatePeers` keeps the engine's `online` verdict for peers that carry one instead of copying the previous list's state | `client/lib/home.dart` groups a host's addresses by its engine id and hides the old leases of a machine the engine's scan did not find. Lists without those keys (recent, favorites) behave exactly as upstream |

Notes:
- Hooks are marked in the code with a `remotedisplay:` comment.
- Everything else `client/` needs from the engine is consumed as a package
  (`flutter_hbb` by path) without modifying it: `RemotePage`, models, toolbar
  helpers (`toolbarImageQuality`/`toolbarCodec`), `handleUriLink`, etc.

## Engine hooks for camera & audio forwarding

Server-side hooks from the [camera & audio forwarding spec](docs/specs/camera-audio-forwarding.md),
listed here as [decision 0008](docs/architecture/decisions/0008-mic-path.md) requires. Same
rules: marked `remotedisplay:`, the logic in a new file, the upstream file only calls it.

| # | File (engine/rustdesk/) | What | Why |
|---|---|---|---|
| E1 | `src/server/audio_service.rs` (`mod host_sound` and the `screencapturekit` `get_device()`), new `src/server/audio_service/host_sound.rs` | With `screencapturekit`, host sound is ScreenCaptureKit's system audio; when that is unavailable or the owner's named input is missing, capture fails instead of falling back to the default input. Voice calls keep upstream's behaviour | The fallback sends the host's microphone, i.e. the room, to every controller (issue #4). Without the feature (the client library) nothing changes |
| E2 | `src/server/connection.rs` (`mod audio_gate`, the `audio_gate` field and its default, the `AudioFormat` and `AudioFrame` checks), new `src/server/connection/audio_gate.rs` | The host accepts a controller's audio only while a voice call it accepted is active (Phase 2 adds an accepted microphone forward), whatever that controller's `disable_audio` says; drops are logged once per stretch | Upstream plays any controller's audio while `disable_audio` is off: nobody accepts it, and turning the host's sound off also silences the controller's mic ([decision 0007](docs/architecture/decisions/0007-host-audio-gate.md), issue #3) |
