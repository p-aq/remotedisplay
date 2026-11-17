# 0017. Reserve `Message.union` 200–219 for Remote Display

- **Status:** Accepted, 2026-10-27. Supersedes [0002](0002-reserved-message-range.md).
- **Original design:** Departs from the spec as first written, which proposed 100–119 and
  left it as an open question for upstream Remote Display's maintainer. Follows
  "additive protobuf changes only".

## Context

[0002](0002-reserved-message-range.md) proposed 100–119 and waited on SamuelRioTz's
agreement (issue #14). This work lives in a fork, p-aq/remotedisplay, which owns its
protocol; the fork's owner decided not to wait on upstream.

What the numbers have to stay clear of, checked on 2026-10-27:

- RustDesk adds messages at the end of the oneof. 1.4.9, our baseline, stops at 32;
  RustDesk's `master` (`13e1278`, where `message.proto` has moved to
  `libs/base/protos/`) already has 33 and 34.
- Upstream Remote Display (`main`, `86f1b23`) stops at 32 and reserves no range.

## Decision

Remote Display's own messages use `Message.union` numbers 200–219, marked with a
`remotedisplay:` comment in `message.proto`. Camera & audio forwarding takes 200–204;
later features take the next free numbers in the block. The spec says so in Protocol
changes.

Why 200 and not 100: both are far from RustDesk's numbers and cost the same on the wire
(field numbers 16–2047 all take a two-byte tag). 100 is the first round number anyone
would pick for a block of their own, including upstream Remote Display if it adds
messages; 200 is less likely to be taken by someone else.

## Consequences

- Upstream additions never collide with ours. A test in the engine
  (`tests/device_forward_messages.rs`) pins 200–204 and fails if an engine update
  brings anything else into 200–219.
- Peers that don't know these numbers decode the message with no content and ignore it,
  so 1.0.x controllers and hosts keep working.
- If upstream Remote Display adopts this work under other numbers, renumbering is one
  file. A renumbered build and this fork then can't forward devices to each other; each
  sees the other's messages as unknown, so the feature just shows as unavailable.
