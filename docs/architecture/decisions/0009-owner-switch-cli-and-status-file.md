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
