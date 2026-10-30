# Camera extension — Phase 0 (2026-10-24)

Measures the risky macOS half of camera forwarding before any engine change (issue #1,
[spec](../../specs/camera-audio-forwarding.md) Phase 0): a camera extension, Remote
Display Camera, fed by a background process through its sink stream, and read by
FaceTime, Zoom and other apps through its source stream.

**Status:** the harness builds, and the codec path (encode, wire format, decode) passes
every check. The extension's gate tests haven't run yet, because they need an Apple
Developer team to sign the extension. Results go in the tables as they come in.

**Phase 1:** the extension and the container app's install and remove are now in Remote
Display Server (`server-mac/CameraExtension/`, Setup's Camera row; [decision
0019](../../architecture/decisions/0019-camera-extension-in-the-server-app.md)). Its sink
accepts only `remotedisplayd`, so the feeder here works only with the harness's own
extension, which keeps its `app.remotedisplay.spike` identifiers.

## What's here

| Harness | What it is | Becomes in Phase 1 |
|---|---|---|
| `harness/CameraExtension/` | The extension (Swift): one device, a source and a sink stream at 1280×720, 30 fps, NV12. Forwards sink frames, drains the sink with or without readers, shows a placeholder card after 500 ms without frames, drops frames of the wrong size or format ([decision 0011](../../architecture/decisions/0011-extension-owns-placeholder.md)). | `server-mac/CameraExtension/` |
| `harness/ContainerApp/` | The app that embeds the extension and asks macOS to activate or remove it (Swift). Window, or `--activate` / `--deactivate` from a terminal. | The Camera row's Install… and Remove buttons in Remote Display Server |
| `harness/camera_sink.mm`, `.h` | Finds the device and pushes pixel buffers into its sink with the CoreMediaIO C API. `extern "C"` `MacCameraSink…` functions, `-std=c++17`, no ARC: the same shape and flags as `src/platform/macos.mm`. | `engine/rustdesk/src/platform/macos_camera_sink.mm`, plus decode ([decision 0005](../../architecture/decisions/0005-annex-b-wire-format.md)) |
| `harness/feeder.mm` | `rd-camera-feeder`: pushes the test card at 30 fps. `--list`, `--seconds`, `--fps`, `--size`, `--snapshot`. Built twice: with a camera usage string and entitlement, and bare (`rd-camera-feeder-bare`), for issue #7. | Replaced by decoded `CameraFrame`s in `remotedisplayd` |
| `harness/test_card.mm`, `.h` | The test card: a moving bar, a millisecond clock and colour bands, drawn straight into NV12. Shared by the feeder and the codec test. | — |
| `harness/camera_codec.mm`, `.h` | H.264 encode with `VTCompressionSession` → Annex B, and Annex B → AVCC → `VTDecompressionSession`, with input limits ([decisions 0004, 0005, 0016](../../architecture/decisions/README.md)). | Encoder: `src/platform/macos_camera_capture.mm`. Decoder: in front of `macos_camera_sink.mm` |
| `harness/codec_test.mm` | `rd-camera-codec-test`: ten checks of the codec path in one process. Needs no camera, extension, signing or permission. | A Phase 1 test |
| `harness/Makefile` | Builds and signs everything with the Command Line Tools ([decision 0014](../../architecture/decisions/0014-phase0-camera-harness.md)). | Folded into `server-mac/Makefile` |

## What was tested and the result

On a Mac mini (Apple silicon, macOS 15.7.7, Command Line Tools with SDK 26.2, no Xcode,
no signing identity):

1. **Build**: `make` builds the extension, the container app and both feeders with no
   warnings (`-Wall -Wextra` on the Objective-C++). **PASS**
2. **Device enumeration**: `rd-camera-feeder --list` lists the Mac's real camera
   (Microsoft LifeCam HD-3000, one stream, direction 1) through CoreMediaIO. **PASS**
3. **No extension**: `rd-camera-feeder` exits with "can't open the sink … OSStatus
   560227702" (`kCMIOHardwareBadDeviceError`) after its 5 s wait. **PASS**
4. **Test card**: `--snapshot` renders the card's luma plane upright, with the clock,
   bar and band where expected. **PASS**
5. **Ad-hoc activation**: `RDCameraSpike --activate` from the build folder is refused:
   "Missing entitlement com.apple.developer.system-extension.install
   (OSSystemExtensionErrorDomain 2)". **As expected**: the extension can't be activated
   without a team-signed app (see Runtime findings).

### Phase 0 gate tests (need a signed build)

| # | Test | How | Passes when | Result |
|---|---|---|---|---|
| 1 | Activate | `make install activate`; an admin approves in System Settings › General › Login Items & Extensions › Camera Extensions | `systemextensionsctl list` shows `[activated enabled]` | Pending |
| 2 | Placeholder | Open Photo Booth, choose Remote Display Camera, no feeder running | The "No controller connected" card | Pending |
| 3 | Background feeder | Start the feeder as its own process (see Re-running), then use the camera in FaceTime, Photo Booth, QuickTime and Zoom | The test card, clock advancing smoothly, colour bands red/green/blue | Pending |
| 4 | Feeder crash | `kill -9` the feeder while Photo Booth shows the card | Placeholder within 1 s | Pending |
| 5 | No reader yet | Start the feeder, open Photo Booth 30 s later | Live card within 1 s; the feeder's "dropped" count stays near 0 | Pending |
| 6 | Wrong size | `--size 640x360` | Placeholder stays up; the extension logs dropped frames | Pending |
| 7 | Camera permission (#7) | Run `rd-camera-feeder-bare`, then `rd-camera-feeder`, each as its own process, on a Mac that never granted either | Record: prompt, silent denial, or works | Pending |
| 8 | Update | `make install activate VERSION=2` with Photo Booth open | Record what Photo Booth shows before and after it relaunches | Pending |
| 9 | Tart image | Approve the extension once in a Tart VM through its window, then snapshot | The snapshot boots with the extension active | Pending |

### Codec path (2026-10-24, issue #2)

`make codec-test` and `make codec-test-asan` on the same Mac mini (Apple M4). 1280×720
at 30 fps and 2 Mbit/s, a key frame at least every 2 s, 300 frames of the test card:

| Check | What it shows | Result |
|---|---|---|
| annex-b-framing | Every access unit starts with a start code; SPS and PPS ride on exactly the key frames | **PASS** (300/300) |
| key-frames | Key frames at the start, on demand, and never more than 2 s apart | **PASS**: 0, 60, 100 (forced), 160, 220, 280. A forced key frame resets the 2 s timer |
| no-reordering | One frame out per frame in, in presentation order (no B-frames) | **PASS** |
| encode-latency | Time from handing a frame to the encoder until its access unit arrives | **PASS**: median 5.1 ms, p95 5.6 ms; the session's first frame takes about 42 ms |
| round-trip | Every frame decodes, and how close it is to the source | **PASS**: 300/300, luma PSNR median 60 dB, min 47 dB; decode median 0.9 ms |
| join-mid-stream | A decoder that starts on a delta frame asks for a key frame until one comes | **PASS**: 50 requests, then 240/240 decoded |
| resolution-change | New SPS/PPS rebuild the decoder, and back again | **PASS**: 640×360 then 1280×720 |
| limits | Streams over 1920×1080, access units over 4 MB and empty input never reach VideoToolbox | **PASS**; a valid key frame decodes straight after |
| bitrate-change | Lowering the target live (`CameraControl`) on noisy content | **PASS**: 1,895 → 488 kbit/s for a 2,000 → 500 target |
| fuzz | Corrupted access units: flipped bytes, truncation, garbage, splices, stray start codes, broken SPS/PPS | **PASS**: 20,000 under AddressSanitizer and UndefinedBehaviorSanitizer, no memory errors; a clean key frame recovered the decoder 200/200 times |

Encoder comparison (both pass every check):

| | `h264.rtvc` (low-latency, hardware required) | `ave.avc` (`--no-low-latency`) |
|---|---|---|
| Encode latency, median / p95 / max | 5.1 / 5.6 / 42.6 ms | 5.6 / 6.2 / 11.2 ms |
| Luma PSNR, median / min | 60 / 47 dB | 50 / 41 dB |
| Bitrate after 2,000 → 500 | 488 kbit/s | 499 kbit/s |

## Runtime findings

- **Low-latency mode uses a different encoder.** Asking VideoToolbox for low-latency
  rate control selects `com.apple.videotoolbox.videoencoder.h264.rtvc`, Apple's real-time
  conferencing encoder. It doesn't support `UsingHardwareAcceleratedVideoEncoder`
  (−12900), so that property can't be used to check for hardware. It is still chosen
  when hardware is *required*, so the encoder asks for hardware up front. A software
  variant, `h264.rtvc.sw`, also exists and is what requiring hardware keeps us off.
- **The first frame of a session is slow** (about 42 ms against about 5 ms afterwards).
  Create the encoder when the camera is switched on, not on the first frame.

- macOS refuses to activate a system extension from an app without
  `com.apple.developer.system-extension.install`, and that entitlement is restricted:
  ad-hoc and unprovisioned builds can't carry it. This is why
  [decision 0010](../../architecture/decisions/0010-entitlements-per-binary.md) keeps it
  out of every binary except the app, and leaves the extension out of builds without a
  profile.
- TCC charges a process launched from Terminal to Terminal (the "responsible
  process"). Test 7 has to start the feeder with `launchctl submit` so it is responsible
  for itself, as `remotedisplayd` is when the server app launches it.

## Re-running

You need an Apple Developer Program team. Xcode isn't required:

1. In the developer portal, create two App IDs: `app.remotedisplay.spike` with the
   System Extension and App Groups capabilities, and `app.remotedisplay.spike.camera`
   with App Groups. Both use the group `<TEAM_ID>.app.remotedisplay.spike`.
2. Create a signing certificate (Apple Development, with this Mac registered as a
   device, or Developer ID Application) and a provisioning profile for each App ID.
3. Build, install and activate:

```sh
cd docs/tests/camera-extension/harness
make SIGN_ID="Apple Development: Name (XXXXXXXXXX)" TEAM_ID=ABCDE12345 \
     APP_PROFILE=~/Downloads/spike_app.provisionprofile \
     EXT_PROFILE=~/Downloads/spike_camera.provisionprofile
make install activate
make list
```

4. Feed it as its own process, so TCC treats it as `remotedisplayd`:

```sh
launchctl submit -l app.remotedisplay.spike.feeder -- "$PWD/build/rd-camera-feeder" --seconds 120
launchctl remove app.remotedisplay.spike.feeder
log stream --predicate 'subsystem == "app.remotedisplay.spike.camera"'
```

5. Remove: `make deactivate`, then delete `/Applications/RDCameraSpike.app`.

The codec checks need none of the above:

```sh
cd docs/tests/camera-extension/harness
make codec-test        # both encoders
make codec-test-asan   # sanitizers, 20,000 fuzzed access units
```

Not covered here: the two microphone options, which get their own harness in
`docs/tests/virtual-mic/`.
