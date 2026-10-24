# 0012. Devices menu always shown; status strings and `DeviceStatus`

- **Status:** Accepted, 2026-10-24 (review findings U-1, U-2, U-3; PR #16)
- **Original design:** Departs from the spec, which showed each switch only when its
  capability flag was present. Follows the client's pattern of owning its toolbar and
  filtering engine toggles in `session_toolbar.dart`.

## Context

The spec both hid switches without a flag and promised to explain why a host can't
receive. `PeerInfo.platform_additions` is sent once at login and never updates, and a
boolean can't say "not installed" versus "not allowed". The engine's Mute toggle
already appears under Input › Session, and would duplicate "Play the Mac's sound here".

## Decision

- The Devices menu is always shown; its sound switch works with 1.0.x hosts. Camera and
  mic rows are disabled with a reason when unavailable.
- `rd_camera_sink` and `rd_mic_sink` are status strings: `ready`, `not-installed`,
  `not-approved`, `not-allowed`.
- A new `DeviceStatus` message (field 104) updates a status mid-session.
- Input › Session stops showing the engine's Mute toggle.
- FFI adds device lists with hot-plug events and the controller's own permission state;
  adding FFI includes regenerating the flutter_rust_bridge bindings.

## Consequences

- One more message in the reserved range.
- The older-peers test changes: against a 1.0.x host, Devices shows the sound switch and
  asks for an update for camera and mic.
