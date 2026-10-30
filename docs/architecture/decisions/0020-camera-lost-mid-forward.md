# 0020. A camera that goes away mid-forward ends the forward, and the host is told

- **Status:** Accepted, 2026-10-28 (issue #2)
- **Original design:** Extends the spec's sending rules ("Stop capture the moment the
  user switches off, the host refuses, or the session ends") with one more case, the one
  decision 0018 left open. Follows the sender's pattern for a forward that stops by
  itself (`no-answer`): stop the camera, tell the host `on: false`, give the menu a
  reason.

## Context

- **How a camera goes away.** A USB camera is unplugged, an iPhone leaves Continuity
  Camera, or the capture session stops on an error (for example when macOS's media
  services restart). AVFoundation posts `AVCaptureDeviceWasDisconnectedNotification` for
  the device and `AVCaptureSessionRuntimeErrorNotification` for the session. Capture
  didn't watch for either.
- **What happened without them.** Frames just stopped:
  - the controller's menu still showed the camera on;
  - the host kept the forward open and the device taken, so another controller got
    `busy`;
  - Remote Display Camera fell back to its placeholder after 500 ms without frames
    (decision 0011), so the call showed that, with neither side saying why.
- **Threads.** The notifications come on AVFoundation's threads, and one can still be on
  its way while the capture stops. Nothing may call into Rust once
  `MacCameraCaptureStop` returns, because the callbacks' context is freed then.

## Decision

- **Capture watches.**
  - `MacCameraCaptureStart` takes a `lost` callback.
  - Before the session starts, it observes both notifications, for its own device and
    session. The first to arrive calls `lost` once, with why: `disconnected`, or the
    error's description.
  - The observers hold a small watch object, not the capture. Stopping clears the watch
    under its lock before anything is freed. So no `lost` call is under way once stop
    returns, and none can start after.
  - The test card never goes away.
- **The sender ends the forward.**
  - `Capture::start` takes `on_lost`, and the sender's `start` passes one per forward.
  - It sets a flag in that forward's shared state and wakes the io loop: `Event::Lost`,
    beside `Unit` and `NoAnswer`. The flag stays set, so a loss that comes while the io
    loop isn't waiting isn't missed.
  - Asking or sending, the io loop then:
    - stops the camera;
    - sends the host `DeviceForwardRequest{CAMERA, on: false}`;
    - reports `forward: off`, `reason: camera-lost`.
  - The host handles it as a switch-off: it stops the sink, Remote Display Camera shows
    its placeholder straight away, and the device is free for another controller.
  - A loss from a camera that was replaced or switched off is ignored. Each forward has
    its own shared state.
- **No fallback and no resume.** The forward doesn't move to another camera, and
  plugging the camera back in doesn't restart it. The user switches the camera on again
  from the menu, which lists the cameras each time it opens. Moving to another camera
  unasked could put a picture into the host's call that the user didn't choose.
- **The menu** shows "The camera was disconnected or stopped working".
- **Only these two notifications end a forward.** Anything else that stops frames
  leaves it on. The host then shows the placeholder after 500 ms until frames come back.

## Consequences

- Both sides show what happened, and another controller can take the camera at once.
- `Capture::start` takes a third argument, and so does the sender's `Start`.
- Unit-tested with the fake camera:
  - lost while sending;
  - lost while asking, which also ends the 10-second wait for the host's answer;
  - lost before the io loop waits;
  - lost after another camera replaced it, or after a switch-off: ignored.
- **Not tested with a real camera:** none is attached to the build Mac now.
  `make unplug` in `docs/tests/camera-capture/harness/` runs the sender with the default
  camera. It passes once a person unplugs the camera within a minute and:
  - the host is told `on: false`;
  - no frame follows;
  - the menu hears `camera-lost`.
- The camera list's hot-plug event stays with Phase 2 (decision 0018).
