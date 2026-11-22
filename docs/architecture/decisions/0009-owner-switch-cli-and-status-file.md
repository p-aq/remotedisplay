# 0009. Owner's switch via user-level CLI; status via the perms file

- **Status:** Accepted, 2026-10-24 (review finding H-1; PR #16)
- **Original design:** Departs from the spec, which reported state "over the existing
  IPC". Follows two existing patterns instead of adding an IPC: `--set-lan-password`
  for commands, `remotedisplay-perms.json` for status.

## Context

The menu-bar app has no IPC to the engine. It polls `remotedisplay-perms.json`,
`pgrep` and `lsof` every 2 s and writes `RemoteDisplay2.toml` only during setup.
`remotedisplayd --option` needs an installed, root process; the app runs as the user,
and editing the TOML doesn't reach a running engine.

## Decision

- Add `remotedisplayd --set-device-forward on|off`, built like `--set-lan-password`:
  no install/root gate, `ipc::set_option("rd-allow-device-forward", …)` on the running
  `--server` as the same user.
- When the option turns off, the engine stops every live forward and tells each
  controller `not-allowed`.
- Forwarding state (device, controller) goes into `remotedisplay-perms.json`, or a
  status file next to it, which the app already polls. Badge updates follow the
  existing menu-open guard.

## Consequences

- No new channel between app and engine; the app's model (poll, don't push) stays.
- Status reaches the menu bar within about 2 s, which is enough for a badge.

## Implementation (2026-10-26)

- `remotedisplayd --set-device-forward on|off` in `core_main.rs`, next to
  `--set-lan-password` (`HOOKS.md` E3). `on` stores `rd-allow-device-forward = "Y"`;
  `off` removes the option, so off stays the default. It honours the same
  CLI-settings policy check as `--set-lan-password`. The logic is in
  `src/server/device_forward.rs`, the file the spec plans for host request handling.
- The `--server` adds `"device_forward": true|false` to `remotedisplay-perms.json` on its
  2 s loop. The app parses that file as `[String: Bool]`, so it can only hold booleans:
  any other value makes the parse fail and the app fall back to its own permission
  checks. The forwarding state (which device, which controller) therefore needs the
  status file next to it, not new keys in this one.
- The app's Settings gains *Let controllers share their camera and microphone*. It runs
  the CLI, shows the chosen value until the engine's file agrees (up to 10 s), and is
  disabled while the service is off, like the password.
- "Stop every live forward and tell each controller `not-allowed`" waits for forwards to
  exist (request handling, Phase 1). Done 2026-10-27: each connection checks the switch
  once a second, ends its camera forward and sends `DeviceForwardResponse{accepted:
  false, reason: "not-allowed"}` plus `DeviceStatus` (decision 0012, Host side).
- Tested: the CLI against a scratch `HOME` with no server running (on stores the option,
  off removes it, anything else is refused and changes nothing); unit test for the
  argument; the engine and the app build. Not tested here: the switch against a live
  `--server`. Running one would put this Mac on the LAN; the path is upstream's
  `ipc::set_option`, the same one the client app uses for every option.

## Forwarding status (2026-10-27)

- **The file:** the `--server` writes `~/Library/Application Support/remotedisplay-forwarding.json`
  on the same 2 s loop as the perms file, atomically in the same way. It holds
  `{"camera": "<controller>"}` while a controller sends its camera, and `{}` otherwise.
  It is a file of its own because the app reads the perms file as booleans only.
- **The name** is the controller's login name, cut to 64 characters, held next to the
  one-sender-per-device record in `device_forward.rs`.
- **The app** reads the file only while the service runs, so a file left by a stopped
  engine names no one. It badges the menu-bar icon with a camera and adds *Camera from
  …* to the menu. Both follow the existing guard: nothing changes while the menu is open.
- **Setup** gains Camera and Microphone rows, as the spec asks. They are optional and
  not counted as to-do. Each says *Not available in this build* until the camera
  extension and the virtual mic are bundled; the Camera row checks for the extension
  inside the app.

## Sessions by name (2026-11-22)

- **The file:** the `--server` writes `~/Library/Application Support/remotedisplay-sessions.json`
  on the same 2 s loop, atomically in the same way: `{"192.168.1.245:37911": "<controller>"}`,
  an entry for each logged-in connection, and `{}` when no one is connected. The UX audit of
  2026-11-21 found that the owner couldn't tell who was connected: Active sessions listed
  each controller as `ip:port`.
- **The key** is the address in the form the app derives from lsof: IPv4, IPv4-mapped IPv6
  reduced to IPv4 as the connection's own `try_into_v4` does, and other IPv6 in brackets
  without a zone. The app now writes plain IPv6 peers that way too (it dropped only the
  closing bracket), and clears the interface index macOS embeds in a link-local address
  (lsof prints `fe80::1` on interface 4 as `fe80:4::1`).
- **The name** is the controller's login name, cut to 64 characters as in the forwarding
  file, added when the login succeeds. `session_names.rs` keeps it in a guard the
  connection owns, so it goes when the connection is dropped, however it ends, the way
  upstream's `AuthedConnID` leaves `AUTHED_CONNS`.
- **The app** reads the file only while the service runs, and lsof stays the list of
  sessions: the file only names its peers, so a missing or stale file changes nothing.
  Active sessions shows the name with the address under it; a peer not in the file (still
  at the password, or an older engine) shows its address alone. The menu says *Alex is
  connected* or *Alex and Sam are connected*, adds *· 3 sessions* when the names don't
  account for every session, and keeps *N active sessions* while no one is named. Both
  follow the existing guard: nothing changes while the menu is open.
- **Tested:** unit tests for the file's shape and the name's cut; the engine's tests and the
  app's build; a one-off check, not committed, that the app's and the engine's code give the
  same key for real loopback, link-local and IPv4-mapped connections and for the IPv6 forms
  lsof showed on this Mac. Not tested here: a live session, which would put this Mac on the
  LAN.
