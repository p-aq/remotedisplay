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
