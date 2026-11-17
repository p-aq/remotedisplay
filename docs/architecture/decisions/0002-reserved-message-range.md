# 0002. Reserve `Message.union` 100–119 for Remote Display

- **Status:** Superseded by [0017](0017-reserved-message-range-200.md), 2026-10-27. Was
  Proposed, 2026-10-23, pending the maintainer's agreement (issue #14).
- **Original design:** Follows the spec. Follows "additive protobuf changes only".

## Context

The engine's `Message` oneof uses field numbers 3–32 today, and upstream RustDesk keeps
adding new ones at the end. If Remote Display took the next free numbers, a later
`engine/update.sh` could bring in upstream messages with the same numbers.

## Decision

Remote Display's own messages use `Message.union` numbers 100–119, marked with a
`remotedisplay:` comment in `message.proto`. Camera & audio forwarding takes 100–104.

## Consequences

- Upstream additions never collide with ours.
- Peers that don't know these numbers ignore them, so older clients and hosts keep
  working.
- If the maintainer prefers a different range, only the numbers change; this record is
  then superseded.
