# Decision records

One record per architectural decision for camera & audio forwarding. See
[../README.md](../README.md) for how they fit together.

Each record says:

- **Status**: Proposed, Accepted, or Superseded by NNNN.
- **Original design**: whether it *follows*, *extends* or *departs from* the spec as
  first written (`4df72ed`), and which repo convention it follows.
- **Context, Decision, Consequences**, kept short.

To add one, copy the newest record, take the next number, and link it from the
architecture README's change log (and its departures table, if it departs).

| # | Decision | Status | Original design |
|---|---|---|---|
| [0001](0001-spec-first-gated-phases.md) | Spec first, delivered in gated phases | Accepted | Follows |
| [0002](0002-reserved-message-range.md) | Reserve `Message.union` 100–119 for Remote Display | Superseded by 0017 | Follows |
| [0003](0003-cameraframe-message.md) | Camera rides the session as its own `CameraFrame` message | Accepted | Follows |
| [0004](0004-camera-encode-videotoolbox.md) | Encode the controller's camera with `VTCompressionSession` | Accepted | Departs |
| [0005](0005-annex-b-wire-format.md) | H.264 Annex B on the wire | Accepted | Extends |
| [0006](0006-camera-channel-drop-before-encode.md) | Own bounded channel for camera frames; drop before encoding | Accepted | Departs |
| [0007](0007-host-audio-gate.md) | Host accepts controller audio only during an accepted forward | Accepted | Extends |
| [0008](0008-mic-path.md) | Mic and sound paths: fixed voice-call capture, low-latency buffer, no mic fallback | Accepted | Departs |
| [0009](0009-owner-switch-cli-and-status-file.md) | Owner's switch via user-level CLI; status via the perms file | Accepted | Departs |
| [0010](0010-entitlements-per-binary.md) | One entitlements file per binary; extension signed first | Accepted | Departs |
| [0011](0011-extension-owns-placeholder.md) | The camera extension owns the placeholder and drains the sink | Accepted | Extends |
| [0012](0012-devices-menu-and-device-status.md) | Devices menu always shown; status strings and `DeviceStatus` | Accepted | Departs |
| [0013](0013-virtual-mic-input-only-driver.md) | Virtual mic as an input-only driver fed by a hidden device (Option A) | Accepted | Extends |
| [0014](0014-phase0-camera-harness.md) | The camera harness follows the repo's harness, engine and server-app patterns | Accepted (Phase 0) | Departs (build only) |
| [0015](0015-virtual-mic-harness.md) | Virtual-mic harness: BlackHole configured, not modified; one engine-side module for both options | Accepted (Phase 0) | Extends; departs from vendoring for Phase 0 |
| [0016](0016-camera-encoder-and-decoder-contract.md) | Camera encoder settings (low-latency, hardware required) and decoder contract (limits, outcomes, sanitizer fuzz) | Accepted | Extends |
| [0017](0017-reserved-message-range-200.md) | Reserve `Message.union` 200–219 for Remote Display | Accepted | Departs |
| [0018](0018-devices-menu-state-and-ffi.md) | The Devices menu hears the forward's state as a session event | Accepted | Departs |
| [0019](0019-camera-extension-in-the-server-app.md) | Remote Display Camera ships in the server app, built by its Makefile; only remotedisplayd feeds it | Accepted | Departs (build); extends |
| [0020](0020-camera-lost-mid-forward.md) | A camera that goes away mid-forward ends the forward, and the host is told | Accepted | Extends |
| [0021](0021-microphone-forward-on-the-host.md) | The host plays a microphone forward into Remote Display Microphone through its own jitter buffer | Accepted | Departs (not through `AudioHandler`); extends |
| [0022](0022-vendored-cpal-excludes-own-audio.md) | cpal is vendored into the engine, and host sound leaves out remotedisplayd's own audio | Accepted | Extends; departs from upstream (cpal from git) |
| [0023](0023-controller-microphone-capture.md) | The controller captures its microphone per forward, not through the voice call's audio service | Accepted | Departs (not `start_voice_call()`); voice processing still to measure |
| [0024](0024-devices-menu-microphone-row.md) | The Devices menu's Microphone row: no hot-plug event, a headphones hint, and none during a voice call | Accepted | Departs (no hot-plug event); extends |
