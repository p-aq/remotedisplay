# 0031. Remote Display Microphone can be the Mac's default input

- **Status:** Accepted, 2026-10-30 (issue #3). Amends decision 0013's "can't become a
  default device".
- **Original design:** Departs from the spec's Option A, which publishes the device
  as "input-only … that can't become a default device, so it never appears under
  Sound › Output". Keeps its goal: the device never appears under Sound › Output. Still
  BlackHole configured by its build constants, unmodified (decisions 0015, 0027).

## Context

- **The first live session** (`docs/tests/live-session/`) found Remote Display
  Microphone missing from System Settings › Sound › Input. `kCanBeDefaultDevice=false`
  answers "can't be the default" for every scope, so macOS leaves it out of Input as
  well as Output, and nothing can make it the Mac's default input.
- **Apps with their own picker list it** (QuickTime did), and Setup tells the owner to
  pick it there. But an app that only records from the default input can't use it. The
  Phase 2 gate names Dictation.
- **The flag was belt and braces.** The output side was already kept away twice:
  - The visible device has no output streams. Apple's header says
    `kAudioDevicePropertyDeviceCanBeDefaultDevice` applies "depending on the scope", and
    a device with no output streams isn't an output device.
  - The feeder is hidden. The header says a hidden device isn't listed "nor can it be
    the default device".
- **BlackHole answers the flag for both devices and both scopes.** Loaded in a test
  process, the built driver says "can be default" for input and output, on the visible
  device and the feeder alike. Answering per scope would mean changing BlackHole's
  source, which decision 0015 avoids.

## Decision

- **Build the driver with `kCanBeDefaultDevice=true`** in `server-mac/Makefile`. Keep
  `kCanBeDefaultSystemDevice=false`, the alert-sound output.
- **Bump the driver's build to 2** (`CFBundleVersion`, short version 1.1). Setup then
  offers *Update…* on a host with build 1.
- **The Phase 0 harness keeps its constants.** Its tests measured them. Its new
  `make default-check` checks the server app's driver once installed:
  - the microphone can be the default input;
  - neither it nor the feeder can be the default output or the system output;
  - the feeder stays hidden from the device list.

  It puts back each default it changes.

## Consequences

- An owner can pick Remote Display Microphone under Sound › Input, and apps that use the
  default input then hear the controller.
- **If every real input goes away,** macOS may fall back to it as the default input, as
  with any input device. It's silent unless a controller is sending, and the host's own
  sound never comes from an input device (decision 0008).
- **An upstream voice call on the host** records the default input. With Remote Display
  Microphone the default, it would record the controller's forwarded microphone, but the
  controller doesn't forward during a voice call (decision 0024), so it stays silent.
- **Tested** (2026-10-30, without an admin): the driver built from the server's Makefile,
  loaded in a test process, answers:

  | | Hidden | Can be default (input, output) | Can be system output | Input / output streams |
  |---|---|---|---|---|
  | Remote Display Microphone | no | yes, yes | no | 1 / 0 |
  | Feeder | yes | yes, yes | no | 0 / 1 |

  Build 1 answered "no" to both "can be default" questions.
- **Not yet:**
  - the install: `make default-check`, then Sound › Input lists it and Sound › Output
    doesn't;
  - *Update…* from build 1;
  - Dictation.

  Each needs an admin.
