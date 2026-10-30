# Host camera: decode, letterbox, sink — Phase 1 (2026-10-27)

Checks the engine's host side of camera forwarding: decoding a controller's H.264,
fitting it to Remote Display Camera's format and feeding the camera extension's sink
(issue #2, [spec](../../specs/camera-audio-forwarding.md) Host side; decisions
[0005](../../architecture/decisions/0005-annex-b-wire-format.md),
[0011](../../architecture/decisions/0011-extension-owns-placeholder.md) and
[0016](../../architecture/decisions/0016-camera-encoder-and-decoder-contract.md)).

**Status:** the decoder and letterbox pass, and so does the fuzz pass under the
sanitizers, which decision 0016 requires. Feeding a real sink waits for a signed,
installed camera extension ([not yet tested](#not-yet-tested)); without one the host
reports the camera as `not-installed` and refuses requests, as designed.

## What's here

| Piece | What it is |
|---|---|
| `engine/rustdesk/src/platform/macos_camera_sink.mm` | The decoder from `docs/tests/camera-extension/harness/camera_codec.mm` and the sink code from its `camera_sink.mm`, moved into the engine unchanged in behaviour except for the size limit (below), plus a VideoToolbox letterbox to the sink's 1280×720. Exports only `MacCameraSinkStatus` and `MacCameraFeed…` (`HOOKS.md` E8) |
| `engine/rustdesk/src/platform/macos_camera_sink.rs` | The Rust side: `sink_present()`, `Feed::open()`, `push()`; two unit tests that need no extension |
| `engine/rustdesk/src/server/device_forward.rs` | On a Mac host, the camera's status comes from the sink (checked at most once a second, only while the owner's switch is on) and an accepted forward decodes on a thread of its own (`DecodeThread`, unit-tested with a fake decoder) |
| `harness/sink_test.mm`, `harness/Makefile` | `rd-camera-sink-test`: streams from the measured encoder and test card in `docs/tests/camera-extension/harness`, decoded by the engine's file. `make test`, `make test-asan` |

## What was tested and the result

Run 2026-10-27 on a Mac mini (Apple M4, macOS 15.7.7, Xcode 26.3). No camera extension
installed.

| # | Test | Passes when | Result |
|---|---|---|---|
| 1 | 720p | Every unit of a 60-frame 1280×720 stream decodes at the sink's size, median luma PSNR ≥ 35 dB | **PASS**: 60/60, 60.2 dB |
| 2 | 4:3 | A 640×480 stream comes out 1280×720 with black bars at the sides | **PASS**: 30/30, luma 16 in the bar |
| 3 | 1080p | A 1920×1080 stream is scaled to 1280×720 without bars | **PASS**: 29/29 (one frame the encoder didn't return in time) |
| 4 | Portrait | A 720×1280 stream comes out 1280×720 with black bars | **PASS**: 30/30, luma 16 in the bar. Failed before the limit change below |
| 5 | Joining mid-stream | P frames before any key frame ask for one; the key frame and what follows decode | **PASS**: 5/5, then decoded |
| 6 | Limits | Empty input, over 4 MB and a 2560×1440 stream are rejected; a good key frame decodes after | **PASS** |
| 7 | Sink status | With no extension: status *not installed*, opening the sink fails with `kCMIOHardwareBadDeviceError` | **PASS** |
| 8 | Fuzz | 3,000 corrupted units (bit flips, truncation, garbage, splices, stray start codes, broken SPS/PPS) never crash; a clean key frame recovers every 100 | **PASS**: 30/30 recoveries |
| 9 | Fuzz under ASan and UBSan | `make test-asan`: the same with 20,000 units, no sanitizer report | **PASS**: no sanitizer report; 16 decoded anyway, 2,409 asked for a key frame, 17,575 rejected; 200/200 recoveries |
| 10 | Engine unit tests | `macos_camera_sink.rs` (garbage, no parameter sets, no sink) and the decode thread (in order, busy, failed decode, stop) | **PASS**: 2 sink tests, 4 decode-thread tests; the host's request check now accepts a 1080×1920 camera and still refuses 1080×2000 |

## Runtime findings

- **The size limit is now 1920×1080 in either orientation.** Decision 0016 checked
  width ≤ 1920 and height ≤ 1080. That rejected every portrait stream, which the
  spec requires to work ("a 1080p or portrait camera never breaks the stream"). The
  long side may now be up to 1920 and the short side up to 1080, the same pixel bound
  turned on its side. The controller's format choice and the host's request check
  follow the same rule. Recorded in 0016.
- **The letterbox fills with video-range black** (luma 16), so bars look black in the
  apps that read Remote Display Camera.
- **Fuzzed input mostly ends in *rejected*.** 2,582 of 3,000 units were refused
  before or by VideoToolbox, 416 asked for a key frame and 2 still decoded. Every
  outcome maps to the one action decision 0016 allows: ask for a key frame.

## Not yet tested

- Feeding a real sink: it needs the camera extension signed with a provisioning profile
  (paid Apple Developer Program) and installed, then a check in Photo Booth or Zoom.
  The CoreMediaIO code is the Phase 0 harness's, which also couldn't be run unsigned.
- Whether opening the sink needs the Camera permission (the spec's open question).
  The server app's `Info.plist` now has `NSCameraUsageDescription` in case it does,
  as the spec asks.
- The placeholder card within 1 s of a session ending: that's the extension's job
  (decision 0011), so it needs the extension too.

## Re-running

From this folder, in a shell with the toolchain (`tools/README.md`):

```sh
source <toolchains>/env.sh
cd harness
make test
make test-asan    # required after any change to the decoder
make clean
```
