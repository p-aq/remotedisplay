# 0018. The Devices menu hears the forward's state as a session event

- **Status:** Accepted, 2026-10-27 (issue #2)
- **Original design:** Departs from the spec's FFI list, which had a
  `session_get_device_forward_state` getter and device-list events. Follows the engine's
  voice-call pattern for session state and the client's pattern of owning its toolbar,
  with one more listed hook in the engine's Dart code.

## Context

The spec lists these FFI calls for the menu: `session_set_device_forward`,
`session_get_device_forward_state` (including the host's latest status),
`list_cameras` / `list_microphones` with a hot-plug event, and
`get_capture_permission` / `request_capture_permission`.

The forward's state lives in the session's io loop (`DeviceForward`, decision 0006),
and it changes there: on the host's answer, `CameraControl`, `DeviceStatus`, a
10-second timeout, the end of the connection. The engine already reports io-loop state
to the UI one way: an `InvokeUiSession` method that Flutter's handler turns into a
session event (`on_voice_call_started`, `on_voice_call_closed`, …). A getter would need
a second copy of the state shared between the io loop and the FFI thread, plus polling
or an event anyway to update an open menu and the toolbar button.

Session events reach Dart only through the fixed `if … else if` chain in
`FfiModel.startEventListener`; unknown names are dropped. The client can't add a branch
from outside.

## Decision

- **State as an event.** `DeviceForward` builds its state as JSON,
  `{"camera": {"forward", "device", "reason", "host"}}`: off, asking or on; the camera
  being sent; why it stopped by itself (the host's reason, `no-answer`,
  `camera-failed`); and the host's status from its latest `DeviceStatus`. On every
  change, and when the io loop ends (off, host status cleared), it calls the new
  `InvokeUiSession::on_device_forward`. Its default body does nothing, like
  `update_empty_dirs`, so the Sciter UI is untouched; Flutter's handler pushes it as the
  `rd_device_forward` session event.
- **One Dart hook** (`HOOKS.md` #3): `FfiModel.deviceForward`, an observable string,
  and a branch that stores the event in it. The client parses it.
- **No getter.** The menu reads `FfiModel.deviceForward`; before the first event the
  forward is off and the host's status comes from `rd_camera_sink` / `rd_mic_sink` in
  the login response, which Dart already has in `pi.platformAdditions`.
- **Calls.** `session_set_device_forward(session_id, kind, on, device)`,
  `main_list_cameras()` (JSON, synchronous), `main_get_capture_permission(kind)`
  (synchronous) and `main_request_capture_permission(kind)` (waits for macOS's
  prompt). Their logic is in `device_forward::ui`; `flutter_ffi.rs` only calls it.
  `main_` follows the engine's naming for calls not tied to a session.
- **The camera list is read each time the menu opens.** No hot-plug event yet.
- **The microphone** reports `unsupported` until Phase 2; its row shows the host's
  reason, or that it isn't available yet.

## Consequences

- One engine Dart hook more (`model.dart`), small and backward-compatible: the engine's
  own app never receives the event.
- Mid-session changes reach the menu and the toolbar button without polling, including a
  connection that drops: the forward shows off and the host's status falls back to the
  new login response.
- A camera plugged in while the menu is open shows up the next time it opens. Unplugging
  the camera being sent isn't handled yet: capture doesn't watch for
  `AVCaptureDeviceWasDisconnectedNotification`, so the forward isn't told, and the case
  hasn't been tested. Left for the hot-plug work, with the microphone list in Phase 2.
- The Dart side of the bridge must be generated with a libclang that matches the SDK
  (Xcode's, as `env.sh` selects Xcode's SDK); the Command Line Tools' libclang can't
  parse the newer SDK's headers and ffigen then types `int32_t` lists as `Int`, which
  doesn't compile. `tools/README.md` has the command.
