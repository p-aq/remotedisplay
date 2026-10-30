#!/bin/sh
# Phase 2 controller-microphone tests in order (../README.md), after `make`. MIC= and
# SPEAKER= pass through to make. Test 4 plays a 1 kHz tone for a second; test 7 speaks
# through the speaker for about half a minute.
set -e
cd "$(dirname "$0")"

echo "== 1. The microphones that can be forwarded (no microphone access needed)"
make --no-print-directory list

echo "== 2. Without microphone access, nothing is captured"
make --no-print-directory revoke
make --no-print-directory nothing

echo "== 3. macOS asks to let rd-mic-capture-probe use the microphone: click Allow"
make --no-print-directory ask

echo "== 4. 10 ms Opus frames from the microphone; a tone through the speaker is heard"
make --no-print-directory sends

echo "== 5. The controller's sender: AudioFormat, then AudioFrames, only after the host accepts"
make --no-print-directory forwards

echo "== 6. Unplug the microphone, or turn the headset off, when asked"
make --no-print-directory unplug

echo "== 7. Apple's voice processing; macOS asks for rd-voice-probe too: click Allow"
make --no-print-directory voice

echo "== Cleaning up: revoking the grants and deleting build/ and the logs"
make --no-print-directory clean
test ! -e ~/Library/Preferences/RemoteDisplay && echo "   ok: no engine config in the real home folder"
