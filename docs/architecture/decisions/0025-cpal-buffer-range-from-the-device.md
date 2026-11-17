# 0025. The vendored cpal reads a device's buffer sizes from the device, as upstream cpal does

- **Status:** Accepted, 2026-10-29 (issues #3 and #4)
- **Original design:** Extends the spec's Speakers and Microphone capture with a second
  change to the vendored cpal (decision 0022), found with a real microphone. Follows how
  the repo carries a fix to third-party code: the smallest change, marked
  `remotedisplay:`, here a port of upstream cpal's own fix.

## Context

- **Each config query opened the device for input.** To report a device's buffer sizes,
  `supported_input_configs`, `supported_output_configs` and both `default_*_config` made
  an audio unit for the device, always with input on, and read the range from it. That
  broke in two ways on this Mac mini (macOS 15.7.7):
  - **Output-only devices had no configs.** Setting an output-only device on a unit with
    input on fails ("Invalid property value"). The Mac mini Speakers and NDI Audio had no
    configs, so `output_devices()` left them out and `default_output_config()` failed.
    The client plays the host's sound through `default_output_device()` and
    `default_output_config()` (`src/client.rs`), so on a Mac whose default output is its
    built-in speakers, *Play the Mac's sound here* had nothing to play through.
  - **Listing inputs waited on the microphone prompt.** Opening an input asks macOS's
    privacy check. In an app that hasn't been answered yet, `input_devices()` waited in
    `AudioUnitSetProperty` until someone answered the prompt, without anyone asking for
    the microphone. The Devices menu lists the microphones (`main_list_microphones`,
    a synchronous call) each time it opens, so it would freeze there.
- **Upstream fixed it.** [RustAudio/cpal#1184](https://github.com/RustAudio/cpal/pull/1184)
  (May 2026) reads `kAudioDevicePropertyBufferFrameSizeRange` from the device itself
  with `AudioObjectGetPropertyData`. No audio unit is made. rustdesk-org/cpal's
  `osx-screencapturekit` branch, which upstream RustDesk pins, doesn't have it.

## Decision

- **Port that function.** `get_io_buffer_frame_size_range` in
  `libs/cpal/src/host/coreaudio/macos/mod.rs` takes the device and reads the range
  from it, as upstream cpal's does. Its four callers pass `self.audio_device_id`, and
  the config queries no longer make an audio unit at all. The streams are unchanged:
  they still make their unit as before, for input or for output.
- **Marked `remotedisplay:`** and listed in `HOOKS.md` (E13), like decision 0022's line.

## Consequences

- Every device cpal lists has its configs, the built-in speakers too, and reading them
  never opens a device. `mic::list()` stays cpal's list, and it answers in about 70 ms
  before macOS has been asked (`docs/tests/mic-capture/`).
- `cpal_reads_each_device_without_opening_it` runs with every `cargo test` on a Mac. It
  fails without the port ("Mac mini Speakers: no configs").
- When the vendored cpal moves to a commit that has upstream's fix, this change goes.
