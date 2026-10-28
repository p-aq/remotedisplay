#!/bin/sh
# Phase 1 controller-camera tests in order (../README.md), after `make`. The camera's
# light comes on for about 9 seconds in test 4.
set -e
cd "$(dirname "$0")"

echo "== 1. The cameras that can be forwarded (no camera access needed)"
make --no-print-directory list

echo "== 2. Without camera access, nothing is captured"
make --no-print-directory revoke
make --no-print-directory nothing

echo "== 3. macOS asks to let rd-camera-probe use the camera: click OK"
make --no-print-directory ask

echo "== 4. 720p H.264 from the camera, decoded by the host's decoder"
make --no-print-directory sends

echo "== Cleaning up: revoking the grant and deleting build/ and the frames"
make --no-print-directory clean
test ! -e ~/Library/Preferences/RemoteDisplay && echo "   ok: no engine config in the real home folder"
