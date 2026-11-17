# 0030. The engine moves to RustDesk 1.5.1, and the speaker path keeps upstream's new playback

- **Status:** Accepted, 2026-10-30 (issue #26)
- **Original design:** Follows `engine/SYNC.md`'s update flow: a pristine snapshot of the
  new tag in a commit of its own, then our diff re-applied with a 3-way merge. Updates to
  1.5.1, the latest 1.5 release, rather than the issue's 1.5.0. Replaces how decision 0029
  reached the speaker path, keeping its limits.

## Context

- **Upstream moved on.** 1.4.9 → 1.5.1 changes 531 files (+79k/−15k). hbb_common moves
  `7e1c392` → `fae47e0`, and the cpal upstream pins `6b374bc` → `96d4da1`. 1.5 adds a
  `base` crate for client-only code: the message proto, option keys, file transfer and
  platform code. `hbb_common` no longer exports `message_proto`.
- **The sync scripts couldn't follow.**
  - `ensure_upstream_tag` fetched from the remote named `upstream`, which in this clone
    is SamuelRioTz/remotedisplay, not RustDesk.
  - `git apply` refused the whole diff, because `message.proto`, where our five
    messages are, had moved to `libs/base/protos/`.
- **18 files conflicted** once the diff applied. Three of them needed design choices:
  - **Audio playback.** 1.5 reworked it. The output callback no longer sleeps, and reads
    the buffer with `try_lock`. Underruns and discards fade over 5 ms. A resampler keeps
    state across frames, and Windows recovers playback. But the buffer policy is still
    a 3 s ring trimmed every 12 s, never below 600 ms. Decision 0029 had replaced that
    buffer wholesale.
  - **The connection must be `Sync`.** 1.5 holds `&Connection` across an `.await`
    (`type_auto_login_password`). Our forwarding state held boxed feeds that are `Send`
    but not `Sync`.
  - **Static screens.** 1.5 refreshes static screens itself (`static_refresh` in
    `video_service.rs`), next to our macOS restart when nothing was sent 2 s after the
    start.

## Decision

- **The scripts** fetch RustDesk's tags by URL, as hbb_common and cpal already are.
  `UPSTREAM_MOVES` in `engine/lib.sh` lists files upstream moved that our diff changes.
  `follow_moves` points our patch at the new place, and the 3-way apply still merges.
  `libs/hbb_common/protos/message.proto` → `libs/base/protos/message.proto` is the first
  entry.
- **Our messages follow `message.proto`** to `libs/base`. Fields 200–204 sit beside
  upstream's new 33 and 34, which is what decision 0017's reserved range is for. Our
  files import `message_proto` from `base`.
- **The speaker path keeps upstream's playback** and takes the spec's limits on top:
  - `AudioBuffer::keep_short` drops the oldest audio, in whole frames, when more than
    100 ms are waiting, back to 40 ms. It signals a discontinuity, so the writer fades
    across the jump.
  - `AudioPlaybackWriter::refill_after_running_dry` waits for 40 ms at the start and
    after running dry.

  The refill is opt-in, set only by `build_output_stream`, so upstream's own playback
  tests keep their behaviour. The jitter buffer stays in `src/client/jitter.rs` for the
  host's microphone path. Its constants are the limits AudioHandler now keeps.
- **The forwards' feeds are kept in a `Mutex`.** They're only ever used through
  `&mut self`, so `get_mut` never locks, and `Forwards`, and with it the connection, is
  `Sync`.
- **Both static-screen mechanisms stay** for now: upstream's `static_refresh`, and our
  restart, which counts what was sent.
- **The rest keep upstream's 1.5.1 code with ours re-added:**
  - **display_service:** our topology gate moves into `check_update_displays`, before
    upstream's new `update_sync_displays`.
  - **connection manager:** `--cm-no-ui` on top of upstream's reworked launch.
  - **trusted devices:** 1.5.1's new code builds `PeerInfoSerde` with
    `..Default::default()`, since it doesn't know our `machine_id`.
  - **Flutter:** the Devices menu's event, the Account tab's removal, and the mobile
    page's controller and key-help override, each on upstream's new logic.
  - **Generated files:** `pubspec.lock` is upstream's.
- **vcpkg isn't updated.** The engine builds and links with the native libraries already
  in `toolchains/vcpkg` (baseline `120deac`). Upstream's `9e593bb` changes the ffmpeg
  and aom ports, which matters for the release build, not for building and testing here.

## Consequences

- **Tested** (2026-10-30, Mac mini M4, macOS 15.7.7):
  - the engine's tests: 304 pass, 18 ignored, upstream's new ones included;
  - ours: forwarding, microphone, sound and jitter;
  - two new speaker-path tests: the trim, and the refill after running dry;
  - the message test;
  - builds: the server, the client library and the macOS client app.
- **Tested since** (2026-10-30):
  - the system-sound gate, which passes as on 1.4.9;
  - a live session with a second Mac on the LAN ([live session](../../tests/live-session/README.md)).
    The host's sound played cleanly with the limits above. `keep_short` trimmed about
    61 ms 9 times in about 25 minutes: at the two session starts, and when the sound
    started again after upstream's host had stopped sending through about 8 s of
    silence. The rest of the time, including 40 s of continuous speech, nothing was
    trimmed.
- **Not yet:**
  - Tailscale or a busy network, listening for a clipped first word;
  - the release build on the release Mac, with upstream's vcpkg baseline;
  - whether `static_refresh` makes our restart redundant on a static screen;
  - the mobile page on a phone.
- The next update runs the scripts as they are now. A file upstream moves again goes
  into `UPSTREAM_MOVES`.
