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
  **Since 2026-11-20** the reasons name the host by the hostname it reports, its first
  label (*"Mac-mini hasn't turned on camera sharing"*), or *"the computer you're
  controlling"* when it reports none. They said *"This Mac"*, which, read on the
  controller, sounded like the controller itself (camera session, 2026-11-19).
  The engine sends the name in lower case, so a sentence that starts with it
  capitalizes its first letter; `localhost` (the engine's fallback) and an address
  count as no name (review, 2026-11-24).
  **Since 2026-11-21** they say where to fix it: *"Turn on camera sharing in Remote
  Display Server's Settings on mac-mini"*, *"Finish setting up Remote Display Camera in
  Remote Display Server's Setup on mac-mini"*, and the same for the microphone (UX audit,
  2026-11-21). Hosts send `not-installed` also for a camera or microphone that is
  installed but waiting for an admin, so the text points at Setup, whose row says which;
  *"An admin needs to allow …"* waits for hosts that send `not-approved` (review,
  2026-11-24).
- `rd_camera_sink` and `rd_mic_sink` are status strings: `ready`, `not-installed`,
  `not-approved`, `not-allowed`.
  **Since 2026-11-20** a refusing `DeviceForwardResponse` can also say `sink-failed`: the
  device is there, but its sink didn't start (the camera extension or the microphone driver
  refused it). Before, the host said `not-installed`, and the controller told the user to
  install a device that was installed (camera session, 2026-11-19).
- A new `DeviceStatus` message (field 104, now 204: [decision 0017](0017-reserved-message-range-200.md)) updates a status mid-session.
- Input › Session stops showing the engine's Mute toggle.
- FFI adds device lists with hot-plug events and the controller's own permission state;
  adding FFI includes regenerating the flutter_rust_bridge bindings.

## Consequences

- One more message in the reserved range.
- The older-peers test changes: against a 1.0.x host, Devices shows the sound switch and
  asks for an update for camera and mic.

## Host side (2026-10-27)

`src/server/device_forward.rs`, hooked into `connection.rs` (`HOOKS.md` E7).

- **The login response** carries `rd_device_forward: 1`, `rd_camera_sink` and
  `rd_mic_sink`, on a Mac host only.
- **Status precedence:** `not-allowed` (the owner's switch is off) comes before
  whatever the sink says.
- **Until the sinks exist:** the camera is `not-installed` until the camera extension's
  sink feeder lands (next). The microphone is `not-installed` until Phase 2.
- **Mid-session changes:** once a second, each connection compares the statuses with
  what it last told its controller and sends `DeviceStatus` for any that changed.
  Nothing is sent before the login response.
- **`not-approved` comes from the sink**, which is the piece that can tell an installed
  but unapproved extension from a missing one.
- **One reason the spec doesn't list:** a request whose size is outside 16×16–1920×1080
  or whose frame rate is outside 1–60 is refused with `bad-format`. The spec's security
  table asks to validate every width, height and frame rate before use (decision 0016).
