#!/bin/sh
# Phase 3 gate tests in order (../README.md), after `make`. Plays a 1 kHz tone through
# the speakers three times; keep other sound off while it runs.
set -e
cd "$(dirname "$0")"

echo "== 1. Screen Recording refused: nothing is sent"
echo "   If macOS asks to let rd-sound-probe record the screen and audio, click Deny."
make --no-print-directory revoke
make --no-print-directory nothing

echo "== 2. Screen Recording allowed: what a controller receives has the tone"
make --no-print-directory revoke
if ! make --no-print-directory hears; then
    echo "   Expected the first time. In System Settings > Privacy & Security >"
    echo "   Screen & System Audio Recording, turn on rd-sound-probe (if asked, choose"
    echo "   Later, not Quit & Reopen), then press Return here."
    read answer
    make --no-print-directory hears
fi

echo "== 3. Same, with the Mac's output muted (recorded, not required)"
muted=$(osascript -e 'output muted of (get volume settings)')
osascript -e 'set volume output muted true'
make --no-print-directory hears || echo "   (no tone with the output muted)"
osascript -e "set volume output muted $muted"

echo "== Cleaning up: revoking the grant and deleting build/"
make --no-print-directory clean
test ! -e ~/Library/Preferences/RemoteDisplay && echo "   ok: no engine config in the real home folder"
