# Review: Camera & Audio Forwarding Spec

*Review of [camera-audio-forwarding.md](camera-audio-forwarding.md) at commit `4df72ed` (branch `feature/camera-audio-forwarding`) · 2026-10-24*

## Purpose

This document lists gaps, wrong assumptions about the current code, and hurdles the spec does not yet plan for. It is meant to be handed to whoever (person or agent) revises the spec. Each finding has:

- **ID**, used to track the edit (e.g. `V-1`).
- **Severity**: **Blocker** (the plan as written won't work), **High** (likely bug, rework or security issue), **Medium** (gap or ambiguity), **Low** (wording or consistency).
- **Spec location**: line numbers in `camera-audio-forwarding.md` at `4df72ed`.
- **Evidence**: code paths relative to the repo root; engine paths are under `engine/rustdesk/`.
- **Recommended spec edit**.
- **Confidence**: **Verified in code** (read in this repo), or **Needs Phase 0 check** (based on Apple platform behaviour that should be confirmed on a real Mac before the spec commits to it).

## How to apply this review

1. Work through the findings in the order of the [summary table](#summary-table); Blockers first.
2. For each finding, change the spec section named in "Spec location", following "Recommended spec edit".
3. Move every "Needs Phase 0 check" item into the spec's Phase 0 gate or Open questions rather than stating it as fact.
4. Answer the spec's existing Open questions with section [O](#o-answers-to-the-specs-open-questions).
5. Update the References section to point at the commit the revised spec was checked against (it says `86f1b23` today; this review used `4df72ed`).

## Summary table

| ID | Severity | Area | One-line summary |
|---|---|---|---|
| V-1 | Blocker | Camera encode | `hwcodec` takes CPU bytes, not `CVPixelBuffer`s; the "no RGBA round trip, straight into hwcodec" plan doesn't fit the code |
| V-2 | High | Camera encode | No way to force a key frame or change bitrate on a running `hwcodec` encoder |
| V-3 | Medium | Camera encode | `hwcodec` availability check is broken on a controller-only Mac |
| V-4 | Blocker | Wire format | H.264 bitstream format (Annex B vs AVCC) is unspecified; VideoToolbox decode needs AVCC + parameter sets |
| V-5 | High | Send path | "Drop after 150 ms queued" can't be measured on the current sender and corrupts H.264 if done after encoding |
| A-1 | High | Host audio | Host drops controller mic audio when "Play the Mac's sound here" is off; also accepts audio nobody authorized |
| A-2 | High | Controller audio | `start_voice_call()` busy-spins a CPU core and won't switch mic device |
| A-3 | High | Latency | `AudioHandler` keeps at least 600 ms buffered and sleeps inside the Core Audio callback |
| A-4 | High | Host sound | With `screencapturekit` on, the host can still fall back to its physical microphone |
| A-5 | Medium | Virtual mic | Option B (taps) has an unmute/echo failure mode; Option A can hijack the default output |
| A-6 | Medium | Echo | Controller without headphones creates echo that host-side AEC can't cancel |
| H-1 | Blocker | Host app | "The existing IPC" between the menu-bar app and the engine doesn't exist; `--option` can't be used |
| H-2 | Blocker | Signing | Adding the restricted entitlement to the shared `Entitlements.plist` breaks `remotedisplayd`, ad-hoc builds and the cert fallback |
| H-3 | Medium | Signing | Extension bundle naming/identifier rules not followed in the spec |
| H-4 | Medium | Camera extension | App group doesn't give a shared container across the `_cmiodalassistants` user |
| H-5 | High | Camera extension | Placeholder after crash/disconnect must come from the extension itself, not the feeder |
| H-6 | Medium | Camera extension | Sink must drain when no host app is reading the camera |
| U-1 | Medium | UX/protocol | Spec contradicts itself on whether the Devices menu appears; capability flags can't say why, and never update |
| U-2 | Low | UX | Duplicate, opposite audio toggles in two menus |
| U-3 | Medium | FFI | No FFI to list cameras/mics or read controller TCC state; codegen and HOOKS.md steps missing |
| U-4 | Medium | Testing | Tart VM bench can't approve system extensions as-is |
| D-1 | Low | Doc | Milestones table is malformed; phase gates and summary disagree on scope |

---

## V. Video pipeline

### V-1 · `hwcodec` takes CPU bytes, not `CVPixelBuffer`s — Blocker

**Spec location:** lines 199–201 (Controller side › Camera capture on macOS).

The spec says to hand NV12 `CVPixelBuffer`s from `AVCaptureVideoDataOutput` "straight to the VideoToolbox H.264 encoder that hwcodec already wraps … with no RGBA round trip", behind the `TraitCapturer` interface in `libs/scrap/src/quartz/`.

**Evidence (Verified in code):**

- `HwRamEncoder::encode` in `libs/scrap/src/common/hwcodec.rs` (≈L232–241) wraps FFmpeg's `ffmpeg_ram` encoder, which takes one contiguous `&[u8]` YUV buffer laid out with FFmpeg's own `linesize`/`offset`. A camera `CVPixelBuffer` is a bi-planar IOSurface with two plane pointers and padded rows, so it must be copied into that layout, and FFmpeg's VideoToolbox wrapper then copies it into a new `CVPixelBuffer` again.
- `quartz::PixelBuffer` in `libs/scrap/src/common/quartz.rs` (≈L85–114) hard-codes `Pixfmt::BGRA`.
- `convert_to_yuv` in `libs/scrap/src/common/convert.rs` (≈L62–197) accepts only BGRA, RGBA and RGB565LE input; NV12 input hits `bail!("unsupported pixfmt conversion …")`.

**Recommended spec edit:** On the macOS controller, encode with `VTCompressionSession` directly (a small Objective-C++ file, mirroring the `VTDecompressionSession` code the spec already plans for the host in `macos_camera_sink.mm`). Feed each captured `CVPixelBuffer` to `VTCompressionSessionEncodeFrame`. That gives a true zero-copy path and also solves V-2. Drop the "behind the same `TraitCapturer` interface" sentence, or limit it to the test-pattern source. Keep `hwcodec` for Phase 4 (Windows).

### V-2 · No forced key frame or live bitrate change — High

**Spec location:** line 208 (key frame on `CameraControl.key_frame_request`), line 191 (host lowers bitrate with `CameraControl`).

**Evidence (Verified in code):** `EncoderApi` in `libs/scrap/src/common/codec.rs` (≈L60–83) and `HwRamEncoder` have no "force key frame" call. Screen capture gets a key frame by tearing down and rebuilding the encoder. Bitrate changes go through `set_quality`, which is not designed for per-message changes on a live camera stream.

**Recommended spec edit:** With `VTCompressionSession` (V-1), use `kVTEncodeFrameOptionKey_ForceKeyFrame` per frame, `kVTCompressionPropertyKey_AverageBitRate` / `DataRateLimits` for live bitrate changes, and `kVTCompressionPropertyKey_RealTime = true`, `AllowFrameReordering = false` (no B-frames) for low latency. Rate-limit key frame requests on the host (for example at most one per 500 ms) to avoid a storm on a lossy link.

### V-3 · `hwcodec` check broken on a controller-only Mac — Medium

**Spec location:** line 26 (Background: "already encodes … with VideoToolbox through hwcodec"), line 200.

**Evidence (Verified in code):**

- `macos::is_installed()` in `src/platform/macos.rs` (L863–871) is true for an app under `/Applications/<app name>.app`.
- When installed, `check_hwcodec()` in `src/ui_interface.rs` (≈L1661–1668) asks a local `--server` over IPC for the codec config.
- The Mac client sets `REMOTEDISPLAY_NO_SERVER=1` (`client/macos/Runner/MainFlutterWindow.swift`, L49), so no local server runs. The client-only fallback that starts the check (`src/server.rs` ≈L648, `src/client.rs` ≈L3204) is gated `#[cfg(windows)]`.
- Result: on a controller-only Mac the hardware encoder list is likely empty.

**Recommended spec edit:** Moot if V-1 is adopted. If `hwcodec` is kept anywhere on the macOS controller, add a task to run the codec check in-process when `REMOTEDISPLAY_NO_SERVER=1` on macOS too, and list it in HOOKS.md.

### V-4 · H.264 bitstream format is unspecified — Blocker

**Spec location:** lines 152–155 (`CameraFrame`), line 223 (host decode).

`CameraFrame.frame` reuses `EncodedVideoFrames` but the spec doesn't say whether the bytes are Annex B (start codes, in-band SPS/PPS) or AVCC (length-prefixed NAL units, parameter sets out of band).

**Evidence (Verified in code + platform behaviour):** FFmpeg/`hwcodec` (Phase 4 Windows) emits Annex B. `VTCompressionSession` emits AVCC with SPS/PPS in the `CMFormatDescription`. `VTDecompressionSession` needs AVCC sample buffers plus a format description built with `CMVideoFormatDescriptionCreateFromH264ParameterSets`; it won't decode raw Annex B.

**Recommended spec edit:** Add to Protocol changes: "`CameraFrame` carries H.264 Annex B, one access unit per `EncodedVideoFrame`, with SPS and PPS in front of every key frame (`key: true`)." Add to Host side: the feeder parses SPS/PPS on key frames, (re)builds the format description when they change, and rewrites start codes into 4-byte lengths before decode. The macOS controller converts its AVCC output to Annex B before sending. This keeps Windows/iPad/Android controllers simple later.

### V-5 · "Drop after 150 ms queued" can't be measured, and dropping encoded frames corrupts H.264 — High

**Spec location:** line 209 (drop rule), line 191.

**Evidence (Verified in code):** In `src/client/io_loop.rs` the session sender (`Remote.sender`, ≈L64–65) is a `tokio::sync::mpsc::UnboundedSender<Data>`. It shares one FIFO with mouse/keyboard events and exposes no queue depth or age. If camera frames are pushed there, input waits behind video whenever TCP backs up. Separately, an H.264 P-frame depends on the frame before it; dropping an already-encoded frame smears the picture until the next key frame (up to 2 s).

**Recommended spec edit:**

- Drop **before** encoding: `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true`, plus a capacity-1 hand-off between capture and encode.
- Give camera frames their own bounded channel (e.g. capacity 2–4) into the io loop, polled after input in a `biased` `select!`, and track bytes/age in flight so the 150 ms rule is measurable.
- If an encoded frame must still be dropped, force a key frame on the next encode.
- Note the hook in HOOKS.md (it touches `io_loop.rs`).

---

## A. Audio

### A-1 · Host audio gate uses the wrong flag — High (bug + security)

**Spec location:** line 187 (mic reuses `AudioFrame` + `Misc.audio_format`; voice-call accept skipped), line 71 (Play the Mac's sound here).

**Evidence (Verified in code):** In `src/server/connection.rs`, incoming `Misc::AudioFormat` (≈L3563) and `Message::AudioFrame` (≈L3659) are only processed when `!self.disable_audio`. `disable_audio` is the controller's "don't play the host's sound to me" option.

1. If the controller turns off "Play the Mac's sound here" while the mic is on, the host silently drops all mic audio.
2. Nothing checks that a voice call or mic forward was accepted. Any connected controller with audio enabled can send `AudioFormat` + `AudioFrame` and play sound through the host today. With mic routing to a virtual mic, that would let a controller inject audio into host calls without the owner's switch.

**Recommended spec edit:** In Host side › Accepting requests, say: incoming controller audio is accepted only while a `MICROPHONE` forward (or a voice call) is active for that connection, independent of `disable_audio`; otherwise drop it and log once. Add a test row: "mic on + host sound off → mic still works" and "audio sent without an accepted request → dropped".

### A-2 · `start_voice_call()` busy-spins and won't switch devices — High

**Spec location:** line 204 ("Reuse it … and let the user pick the input device").

**Evidence (Verified in code):** `src/client/io_loop.rs`:

- The thread spawned in `start_voice_call()` (≈L504–544) loops on `rx.try_recv()` and `rx_audio_data.try_recv()` with no blocking receive or sleep, so it uses a full CPU core for the whole call.
- L489 calls `set_voice_call_input_device(get_default_sound_input(), false)`. In `src/server/audio_service.rs` (L49–57), `set_if_present = false` keeps any device already set, so a later device change is ignored.
- The selected device is a process-wide global (`VOICE_CALL_INPUT_DEVICE`, L26), and `AUDIO_ZERO_COUNT` (L466) is a `static mut`, so two sessions share state.

**Recommended spec edit:** Change "Reuse it" to "Reuse it with fixes": blocking/timeout receive instead of `try_recv` spin; pass the chosen device with `set_if_present = true` and restart capture on change; scope device selection per session. Record the touch in HOOKS.md.

### A-3 · Audio buffering adds ≥600 ms and sleeps on the real-time thread — High

**Spec location:** line 231 (reuse `AudioHandler::start_audio` with a target device), goals for mic/speakers, Testing (lip sync).

**Evidence (Verified in code):** `src/client.rs`:

- `AUDIO_BUFFER_MS = 3000` (L135) sizes the ring buffer.
- `try_shrink` only drops data every ~12 s, keyed off a shared `static mut tms` (≈L1242), and never shrinks below 600 ms (`if max < 6 { return; }`, ≈L1277).
- The output callback calls `std::thread::sleep(...)` (≈L1507) inside the Core Audio I/O callback, which can cause glitches.
- The host plays controller audio through the same path (`start_audio_thread` → `AudioHandler`, ≈L3114).

**Recommended spec edit:** Add a requirement: the virtual-mic and speaker paths use a separate low-latency jitter buffer (target 40–100 ms, drop-oldest on overflow, silence on underrun, no sleeping in the callback). Set a latency target for the mic path in the Testing plan instead of "measured".

### A-4 · Host can still send its physical microphone with `screencapturekit` on — High

**Spec location:** line 233 (Speakers), Phase 3 gate (line 306), Testing row "Speakers" (line 284).

**Evidence (Verified in code):** In `src/server/audio_service.rs`, the `screencapturekit` `get_device()` (≈L263–281) falls back to `get_audio_input(...)` when the `audio-input` option is set or `is_screen_capture_kit_available()` is false. `get_audio_input("")` ends at `HOST.default_input_device()` (≈L337), the host's microphone.

**Recommended spec edit:** In Host side › Speakers: "On the Mac host, system-sound capture never falls back to an input device. If ScreenCaptureKit audio is unavailable, the speaker feature reports unavailable." Make it a code change in Phase 3, not just a build flag. Note the release script builds both the client library and the server; the feature must only change the server's loopback, not the client's mic capture.

### A-5 · Virtual mic option risks — Medium (Needs Phase 0 check)

**Spec location:** lines 229–230, Open questions lines 315–316.

- **Option B (taps):** a tap muted with "muted when tapped" behaviour is only muted while something is reading the tap. Before Zoom opens the device, or after it closes it, `remotedisplayd`'s mic playback may come out of the host speakers, and the host's ScreenCaptureKit loopback would send it back to the controller (the controller hears themselves). Cross-process use of an aggregate device built on another process's tap, and the audio-capture TCC prompt, are also unproven.
- **Option A (BlackHole):** stock BlackHole exposes input and output on one device. A device with output streams can be chosen, by the user or by macOS, as the system output; then all host sound, including the far end of the call, goes into the virtual mic.

**Recommended spec edit:** Add both failure modes to Phase 0's gate. For Option A, specify the device layout in the spec (see O-3): an input-only visible "Remote Display Microphone" plus a hidden output-only feeder, or an input-only device fed through shared memory.

### A-6 · Echo with controller speakers + mic — Medium

**Spec location:** Testing row "Microphone" (line 283: "the host's sound doesn't echo back"), Open question line 320.

Far-end voice → host ScreenCaptureKit → controller speakers → controller mic → host virtual mic → back into the call. The round-trip delay (network + buffers, often 100–300 ms+) and the fact that the "speaker" is on another machine mean the host app's echo canceller has no usable reference.

**Recommended spec edit:** Either capture the controller mic with Apple voice processing (`AVAudioEngine` input node with voice processing enabled, or `VoiceProcessingIO`), which cancels echo against the controller's own speaker output, or state that v1 needs headphones and show a hint in the Devices menu when both switches are on. Add a no-headphones row to the Testing plan.

---

## H. Host app, signing and camera extension

### H-1 · No IPC between the menu-bar app and the engine — Blocker

**Spec location:** line 239 ("over the existing IPC"), line 184 (owner switches it off mid-session), line 237 (`rd-allow-device-forward`), line 79 (badge naming the controller).

**Evidence (Verified in code):**

- `server-mac/Sources/RemoteDisplayServer/ServerController.swift` has no IPC client. It polls `~/Library/Application Support/remotedisplay-perms.json` (written by `src/platform/macos.rs`), `pgrep` and `lsof` every 2 s, and writes `RemoteDisplay2.toml` only during setup.
- `remotedisplayd --option` (`src/core_main.rs` L627–640) requires `is_installed() && is_root()`. The menu-bar app runs as the user, so this always fails. Editing the TOML directly doesn't reach the running engine, which keeps options in memory.
- The repo already has the right pattern: `--set-lan-password` (L529+) skips the gate and talks to the running `--server` over IPC as the same user.

**Recommended spec edit:**

- Add a non-root CLI command (e.g. `--set-device-forward on|off`) following `--set-lan-password`, which calls `ipc::set_option("rd-allow-device-forward", …)`.
- When that option turns off, the engine tells each live connection to stop forwarding and send `DeviceForwardResponse{accepted: false, reason: "not-allowed"}`.
- Report the forwarding state (device, controller name) by extending `remotedisplay-perms.json` (or a sibling status file) that the app already polls.
- Note the existing crash guard in `ServerController.swift` (≈L87–96): don't change observed state while the menu is open; badge updates must use the same guard.

### H-2 · Restricted entitlement in the shared entitlements file breaks builds — Blocker

**Spec location:** lines 264–268 (Packaging, signing and distribution).

**Evidence (Verified in code):** `server-mac/Makefile` (≈L50–61) signs `remotedisplayd`, `RemoteDisplayServer` and the app bundle with the same flags: `--identifier app.remotedisplay.server --entitlements Entitlements.plist`. `server-mac/sign-identity.sh` picks a Developer ID Application identity and falls back to Apple Development; with none, `SIGN_ID` is empty (ad-hoc).

If `com.apple.developer.system-extension.install` is added to `Entitlements.plist` (Needs Phase 0 check for the exact failure, but this is the known behaviour of restricted entitlements):

1. `remotedisplayd`, a separate executable, would claim a restricted entitlement under the app's identifier; it doesn't need it and risks being killed at launch.
2. Ad-hoc and contributor builds have no provisioning profile, so the app would be killed at launch.
3. A Developer ID profile doesn't match an Apple Development signature (or the reverse), so the cert fallback breaks.

**Recommended spec edit:** Specify separate entitlement files: one for `remotedisplayd` (unchanged), one for the app with the install entitlement and app group, one for the extension. The Makefile embeds the provisioning profile that matches the chosen identity, and builds without a profile drop the restricted entitlement (camera row shows "not available in this build"). Keep the explicit designated requirement as the spec says.

### H-3 · Extension bundle naming — Medium (Needs Phase 0 check)

**Spec location:** line 264 (`Remote Display Camera.systemextension`).

System extensions are found in `Contents/Library/SystemExtensions/` and activated by bundle identifier; Apple's template names the bundle after its identifier, and the identifier is expected to be prefixed by the app's (e.g. `app.remotedisplay.server.camera`). The extension must be signed on its own (own identifier, entitlements, profile) before the app, without `--deep`.

**Recommended spec edit:** Use `app.remotedisplay.server.camera.systemextension` (user-facing name stays "Remote Display Camera" via the device name). State the signing order explicitly.

### H-4 · App group doesn't mean shared storage — Medium (Needs Phase 0 check)

**Spec location:** lines 225, 265–266.

The extension runs as `_cmiodalassistants`, a different user from the console user that runs `remotedisplayd` and the app. A shared app-group container or shared `UserDefaults` won't work across users. The app group is still needed for the extension's mach service name.

**Recommended spec edit:** Add: "All data between `remotedisplayd` and the extension travels through the sink stream (and, if needed, custom CoreMediaIO properties). No files or defaults are shared."

### H-5 · Placeholder after a crash must come from the extension — High

**Spec location:** line 222 (extension shows the card while the sink is idle), line 252 (placeholder within 1 s of the session ending), Testing row "Disconnect".

If `remotedisplayd` crashes or is killed, nothing pushes a placeholder.

**Recommended spec edit:** Specify that the extension runs its own timer: if no sink buffer arrives for 500 ms, the source stream emits the card at a low frame rate until frames return. Add a test: kill `remotedisplayd` mid-call → card within 1 s.

### H-6 · Draining the sink with no reader — Medium (Needs Phase 0 check)

**Spec location:** lines 222–223.

If the controller turns the camera on before any host app opens Remote Display Camera, the extension's source stream has no client. The extension must still consume and discard sink buffers (or signal back) so the feeder's enqueue doesn't fill up and stall.

**Recommended spec edit:** Add the rule to the extension bullet, and a test: camera on, then open Photo Booth 30 s later → live frames within 1 s.

---

## U. UX, protocol, FFI and testing

### U-1 · Devices menu visibility contradicts itself; capability flags too thin — Medium

**Spec location:** line 73 (menu explains why the host can't receive), line 178 (switch shown only when flag present), line 288 (older host → no Devices menu).

**Evidence (Verified in code):** `platform_additions` is built once in `src/server/connection.rs` (≈L1726–1783) and sent with the login response; it never updates during a session. Two booleans can't express "not installed" vs "not allowed".

**Recommended spec edit:**

- Always show Devices (it also holds "Play the Mac's sound here", which works on 1.0.x hosts). Show camera/mic rows disabled with a reason when unavailable.
- Replace the booleans with status strings, e.g. `rd_camera_sink: "ready" | "not-installed" | "not-approved" | "not-allowed"`.
- Let the host send an unsolicited status update (e.g. `DeviceForwardResponse` with `accepted: false` and a reason, or a new small status message) when the owner changes the setting or finishes installing mid-session.

### U-2 · Duplicate audio toggle — Low

**Spec location:** line 71.

**Evidence (Verified in code):** `client/lib/session/session_toolbar.dart` (≈L508–520) shows the engine's session toggles from `toolbarDisplayToggle` under Input, which include RustDesk's mute/disable-audio toggle.

**Recommended spec edit:** Say that the existing audio toggle is filtered out of Input › Session when the Devices menu adds "Play the Mac's sound here".

### U-3 · Missing FFI and generated-code steps — Medium

**Spec location:** line 212.

**Recommended spec edit:** Add FFI calls to list cameras and microphones (with hot-plug updates) and to read/request the controller's Camera and Microphone permission state, so the menu can show "Allow camera access in System Settings". Add the steps to regenerate the flutter_rust_bridge bindings (Dart side and `client/macos/Runner/bridge_generated.h`), and list the new engine touches in HOOKS.md and engine/SYNC.md.

### U-4 · Tart VM bench and system extensions — Medium (Needs Phase 0 check)

**Spec location:** line 277.

Approving a system extension needs a real click in System Settings (synthetic clicks are generally refused), and camera extensions in VMs may need SIP relaxed plus `systemextensionsctl developer on`.

**Recommended spec edit:** Add a Phase 0 task to prepare a Tart base image for extension testing (or do the approval click once through the VM window and snapshot), and keep at least one physical-Mac pass for the approval flow.

### D-1 · Document consistency — Low

**Spec location:** lines 299–308, lines 36–46, line 335.

- The Milestones table has extra `|---|---|---|` rows (lines 301 and 303) that render as junk rows.
- References pin commit `86f1b23`; the branch is at `4df72ed`.
- Goals list speakers in v1, but the camera/mic phases don't depend on Phase 3; say explicitly that v1 = Phases 1–3.

---

## O. Answers to the spec's open questions

**O-1 · Does a process that only feeds a sink stream need the Camera permission?** (spec line 314) — Needs Phase 0 check. Plan for yes: add `NSCameraUsageDescription` to `server-mac/Info.plist` so that a CoreMediaIO call that triggers a camera privacy check can't terminate `remotedisplayd`, and add a Setup row only if Phase 0 shows a prompt.

**O-2 · Option A or Option B?** (line 315) — Lean Option A for v1 (known to work, predictable across engine restarts), with the device layout in O-3. Keep Option B as a spike, and add A-5's unmute/echo case to its gate.

**O-3 · Can the driver hide its output side?** (line 316) — Yes, by design rather than by hiding: publish "Remote Display Microphone" as an input-only device (no output streams, so it never appears under Sound › Output), and feed it either through a second output-only device marked hidden (`kAudioDevicePropertyIsHidden`), which `remotedisplayd` opens by UID, or through shared memory. Confirm in Phase 0.

**O-4 · Does installing a HAL plug-in still need a coreaudiod restart?** (implied by line 229) — Expect yes for first install; use `launchctl kickstart -k system/com.apple.audio.coreaudiod` inside the existing admin-prompt step. Confirm on macOS 14 and 26.

**O-7 · Does ScreenCaptureKit sound capture interfere with a call on the host?** (line 320) — Covered by A-4 and A-6; add the no-headphones test.

The remaining questions (formats, lip sync, cameras per host, message range, upstreaming) are product decisions this review doesn't change.

## Code references used

Paths are relative to the repo root at `4df72ed`; line numbers are approximate (≈) where code may shift.

- `engine/rustdesk/libs/scrap/src/common/hwcodec.rs` — `HwRamEncoder`
- `engine/rustdesk/libs/scrap/src/common/codec.rs` — `EncoderApi`
- `engine/rustdesk/libs/scrap/src/common/convert.rs` — `convert_to_yuv`
- `engine/rustdesk/libs/scrap/src/common/quartz.rs` — `PixelBuffer`
- `engine/rustdesk/src/client/io_loop.rs` — `Remote.sender`, `start_voice_call()`
- `engine/rustdesk/src/client.rs` — `AUDIO_BUFFER_MS`, `try_shrink`, output callback, `start_audio_thread`
- `engine/rustdesk/src/server/connection.rs` — audio gates, `VoiceCallRequest`, `platform_additions`
- `engine/rustdesk/src/server/audio_service.rs` — `get_device()`, `get_audio_input`, `set_voice_call_input_device`
- `engine/rustdesk/src/core_main.rs` — `--option`, `--set-lan-password`
- `engine/rustdesk/src/platform/macos.rs` — `is_installed()`
- `engine/rustdesk/src/ui_interface.rs` — `check_hwcodec()`
- `server-mac/Makefile`, `server-mac/sign-identity.sh`, `server-mac/Entitlements.plist`, `server-mac/Info.plist`
- `server-mac/Sources/RemoteDisplayServer/ServerController.swift`
- `client/lib/session/session_toolbar.dart`, `client/macos/Runner/MainFlutterWindow.swift`
