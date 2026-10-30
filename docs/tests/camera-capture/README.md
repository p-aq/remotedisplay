# Controller camera — Phase 1 (2026-10-27)

Checks that a controller Mac captures its camera and hands out H.264 the host can
decode (issue #2, [spec](../../specs/camera-audio-forwarding.md) Controller side ›
Camera capture and encode on macOS; decisions
[0004](../../architecture/decisions/0004-camera-encode-videotoolbox.md),
[0005](../../architecture/decisions/0005-annex-b-wire-format.md),
[0006](../../architecture/decisions/0006-camera-channel-drop-before-encode.md) and
[0016](../../architecture/decisions/0016-camera-encoder-and-decoder-contract.md)).

**Status:** capture and encode pass on this Mac with a USB camera: 1280×720 at 29.8 fps from Apple's low-latency hardware encoder, and the host's decoder decodes every unit. Without camera access nothing is captured. Still to do: the sender that wraps
these units in `CameraFrame`, the Devices menu, and other cameras
([not yet tested](#not-yet-tested)).

## What's here

| Piece | What it is |
|---|---|
| `engine/rustdesk/src/platform/macos_camera_capture.mm` | Capture and encode (`HOOKS.md` E5): `AVCaptureSession` in NV12 → `VTCompressionSession` with the encoder settings measured in `docs/tests/camera-extension/` → H.264 Annex B, SPS and PPS in front of each key frame. Lists cameras without Remote Display Camera; picks the camera's own format closest to the request, up to 1920×1080; drops frames only before encoding (decision 0006) |
| `engine/rustdesk/src/platform/macos_camera_capture.rs` | The Rust side: `list()`, `access()`, `request_access()`, `Capture::start()` with `request_key_frame()`, `set_bitrate()`, `set_skipping()`, `stats()`; dropping a `Capture` stops the camera. Its `capture` module holds four `#[ignore]`d tests, described below |
| `harness/Makefile` | Builds the engine's test binary and wraps it as `rd-camera-probe.app`, so camera access is asked for and granted to that bundle and not to the terminal; builds `rd-camera-decode`. Targets `list`, `nothing`, `ask`, `sends`, `revoke`, `clean` |
| `harness/decode.mm` | `rd-camera-decode`: decodes the stream the capture test saved with the host's decoder from `docs/tests/camera-extension/harness/camera_codec.mm`, checks the last frame is a picture (luma spread, chroma near neutral) and writes it as a PNG, which `make clean` deletes |
| `harness/gate.sh` | The tests in order, with the prompt to answer; ends by revoking the grant and deleting the bundle and the frames |
| `harness/probe-Info.plist` | The bundle's identity, `app.remotedisplay.spike.camera-probe`: no Dock icon, the camera usage text macOS requires, and the Continuity Camera key |

## What was tested and the result

Run 2026-10-27 on a Mac mini (Apple M4, macOS 15.7.7, Xcode 26.3) from an agent's shell,
with a person answering the camera prompt. The camera is a Microsoft LifeCam HD-3000
(USB); the Mac mini has no built-in one.

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | Build | `make` | The engine builds with the new `.mm`; no warnings from our files | **PASS**: no new warnings. The `.mm` also compiles warning-free for macOS 11.0 and 15.0 targets |
| 2 | Annex B parsing | `cargo test --lib platform::macos_camera_capture` | The test helper finds NAL types after start codes | **PASS** |
| 3 | Cameras listed | `make list` | At least one camera, none of them Remote Display Camera; needs no camera access | **PASS**: *Microsoft® LifeCam HD-3000* |
| 4 | Access refused | `make revoke`, then `make nothing` | `Capture::start` fails with "camera access not allowed"; no unit arrives | **PASS** |
| 5 | Prompt | `make ask` | macOS asks; OK grants access | **PASS**: answered in 43 s; again after the rebuild ([findings](#runtime-findings)) |
| 6 | Capture and encode | `make sends` | See the checks below | **PASS**: 1280×720, 30 fps, `h264.rtvc` with the hardware required. 119 units in the first 4 s (29.8 fps, 1,918 kbit/s), 4 key frames; key frame on request, skipping and stop as required. The first run failed only the stop check, which wrongly counted a unit handed out *during* stop; the test now drains that one first ([findings](#runtime-findings)) |
| 7 | Decodes on the host | `rd-camera-decode` on what test 6 sent | Every unit decodes; the last frame is a picture | **PASS**: 193 of 193 decoded, none needing a key frame, none rejected. Last frame 1280×720, luma mean 100, spread 52.7, chroma mean 128. The first run's 192 units decoded the same way |
| 8 | Nothing left behind | `make clean` | Grant reset, bundle unregistered and deleted, frames deleted, no `~/Library/Preferences/RemoteDisplay` | **PASS**; also no Launch Services entry and no probe process left |

Test 6 starts the default camera at the spec's 1280×720, 30 fps, 2 Mbit/s and checks:

- the format is 1280×720 and the frame rate at most 30;
- at least 40 units in the first 4 s;
- the first unit is a key frame; every key frame starts with SPS and PPS and has an IDR
  slice, every other unit has a P slice and no SPS;
- timestamps only increase; key frames are at most 2.1 s apart, and one arrives within
  three units of `request_key_frame()`;
- with skipping on for 1 s, at most one unit (the one already in the encoder) and at
  least 5 frames counted as skipped; at least 5 units in the second after skipping ends
  and after `set_bitrate(500)`;
- no frame refused by the encoder or of the wrong size;
- after the `Capture` is dropped, nothing more arrives.

Final run: 227 frames captured, 193 encoded, 34 skipped (the second with skipping on, plus the camera's first frames), 0 busy, 0 of the wrong size, 0 refused by the encoder. One unit arrived while stopping, none after. In the second after `set_bitrate(500)` the units added up to 404 kbit/s.

## Runtime findings

- **The low-latency hardware encoder is what runs**: `h264.rtvc` with the hardware
  required, the first choice of decision 0016's fallbacks.
- **The encoder keeps up**: no frame was dropped because the previous one was still
  in the encoder (`busy` 0), so the one-frame slot costs nothing at 720p30 on an M4.
- **Units arrive while the capture stops.** Stopping flushes the frame the encoder is
  working on, and that unit is handed out before `Drop` returns. Nothing arrives after.
  The sender must expect a last unit during stop, which is harmless.
- **Continuity Camera needs a plist key.** Without `NSCameraUseContinuityCameraDeviceType`
  in the app's `Info.plist`, AVFoundation logs a warning and leaves iPhones out of the
  list. The probe and `client/macos/Runner/Info.plist` both have it.
- **An ad-hoc signed probe loses its camera grant on every rebuild**: TCC pins the
  code hash, so the rebuilt binary is a new app with access *not determined*. Answer
  the prompt again after each `make` (or sign with a stable identity, `SIGN_ID=`).
- **The prompt waits for a person.** Unanswered, `make ask` gives up after 5 minutes;
  tccd logs `AUTHREQ_PROMPTING … kTCCServiceCamera` when it shows it
  (`/usr/bin/log show --predicate 'process == "tccd"'`; plain `log` is a zsh builtin).
- From the system-sound harness, still true here: `open --stdout` can't write to an
  external drive (logs go to the system temp folder) and `tccutil reset` needs the
  bundle registered with Launch Services.

## Not yet tested

- Other cameras: a built-in FaceTime camera, Continuity Camera, a camera with only
  4:3 or 1080p formats, and unplugging the camera while it runs.
- Low light, where cameras lower their frame rate on their own.
- The bitrate change's effect over time: the encoder's tracking of a live change was
  measured in `docs/tests/camera-extension/` (2,000 → 500 kbit/s within 3%); here only
  that the change is accepted.
- The sender (`src/client/device_forward.rs`): `CameraFrame`, its own bounded channel,
  the 150 ms backlog rule and the camera turning off when the host refuses. And the
  client app itself, which needs Flutter.

## Re-running

From this folder, in a shell with the toolchain (`tools/README.md`):

```sh
source <toolchains>/env.sh
cd harness
make
./gate.sh     # click OK when macOS asks about the camera; the light comes on for ~9 s
```

After any `make`, the probe needs the prompt answered again (see above).
