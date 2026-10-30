# 0024. The Devices menu's Microphone row: no hot-plug event, a headphones hint, and none during a voice call

- **Status:** Accepted, 2026-10-29 (issue #3)
- **Original design:** Follows the spec's UI (a Microphone switch with a picker, the
  controller's own access) and decision 0018 (state from the `rd_device_forward` event,
  lists read when the menu opens). Departs from "list_microphones(), with an event when a
  device is plugged in or removed". Shows the spec's headphones hint before Phase 2 has
  measured voice processing. Adds what the spec leaves open about a voice call.

## Context

- **Hot-plug.** Decision 0018 read the camera list each time the menu opens and left the
  plug-in event to come "with the microphone list in Phase 2". The menu is a pop-up, so
  it's rebuilt each time it opens. A forwarded device that goes away already ends the
  forward, and the menu hears that through `rd_device_forward` (decisions 0020 and 0023).
- **Echo.** Without headphones, the host's sound played on the controller reaches its
  microphone and goes back into the host's call. The spec's first answer, Apple's voice
  processing, isn't built: it needs measuring with a microphone (decision 0023). Its
  fallback is a hint when both Microphone and *Play the Mac's sound here* are on.
- **Voice calls.** A voice call sends the controller's microphone too. During a
  microphone forward, the host plays everything from that controller into Remote
  Display Microphone (decision 0021), so the two streams would mix there.

## Decision

- **Lists.** `main_list_microphones` returns the controller's inputs by name, without
  Remote Display Microphone, which the capture also refuses. Both lists are read each
  time the menu opens; there's no hot-plug event.
- **The row**, in the camera row's order:
  - on or starting, with the input's name, or the hint below;
  - the host's reason when it can't receive;
  - "End the voice call to send your microphone" during a voice call;
  - the controller's access when it's denied or restricted, with System Settings' pane
    for a denial;
  - "No microphone found";
  - otherwise off, with why the last forward stopped.
  A picker lists the inputs when there's more than one, and the choice is kept for next
  time, like the camera's.
- **Access.** Turning the microphone on asks macOS first, if it hasn't been asked. The
  forward starts only once allowed (the capture refuses otherwise).
- **The hint.** While the microphone is on and *Play the Mac's sound here* is on, the row
  says "Use headphones, or the call hears its own echo". It stays until voice processing
  is measured and either replaces it or isn't enough.
- **The Devices button** is filled while the camera or the microphone goes to the host.

## Consequences

- No new event between engine and client. A device plugged in while the menu is open
  shows the next time it opens.
- Starting a voice call while the microphone forward is on isn't stopped from the menu.
  The two would mix on the host until one is turned off.
- Unit-tested in `client/test/devices_test.dart` (reasons, the hint, the list and the
  pick). The row itself isn't seen in a live session yet.
