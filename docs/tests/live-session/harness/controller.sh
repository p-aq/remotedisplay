#!/bin/bash
# Remote Display live-session test (../README.md), on the Mac that controls, when it isn't
# the Mac the client was built on. AirDrop it in one folder with the client
# (client/build/macos/Build/Products/Release/RemoteDisplay.app), then run from Terminal
# there:
#
#   bash controller.sh before   notes what's on this Mac, then moves the app to /Applications
#   bash controller.sh after    removes only what the test added, and shows what differs
#
# It stops at "before" if the client is already here, so it never deletes anything the
# test didn't add: "before" leaves installed.txt beside this script once the app is in
# place, "after" removes only with that file there, and deletes it when nothing of the
# test is left.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
MARK="$DIR/installed.txt"
APP="/Applications/RemoteDisplay.app"
ID=app.remotedisplay.client
OURS=(
  "$APP"
  "$HOME/Library/Preferences/RemoteDisplay"
  "$HOME/Library/Preferences/$ID.plist"
  "$HOME/Library/Logs/RemoteDisplay"
  "$HOME/Library/Application Support/$ID"
  "$HOME/Library/Saved Application State/$ID.savedState"
  "$HOME/Library/Caches/$ID"
  "$HOME/Library/HTTPStorages/$ID"
  "$HOME/Library/HTTPStorages/$ID.binarycookies"
  "/tmp/RemoteDisplay-$(id -u)"
)

snapshot() {
  echo "## system"; sw_vers; uname -m
  for d in ~ ~/Library ~/Library/LaunchAgents ~/Library/Preferences ~/Library/Logs \
      "$HOME/Library/Application Support" "$HOME/Library/Saved Application State" \
      ~/Library/Caches ~/Library/HTTPStorages /Applications; do
    echo "## $d"; ls -A "$d" 2>&1
  done
  echo "## /tmp RemoteDisplay"; ls -d /tmp/RemoteDisplay* 2>/dev/null
  echo "## audio defaults"
  system_profiler SPAudioDataType 2>/dev/null \
    | grep -E "^        [^ ].*:$|Default (Input|Output|System Output) Device: Yes" | grep -B1 Default
  echo "## volume"; osascript -e 'get volume settings'
}

case "${1:-}" in
before)
  found=0
  for p in "${OURS[@]}"; do
    [ -e "$p" ] && { echo "Already here: $p"; found=1; }
  done
  if [ "$found" = 1 ] && [ -f "$MARK" ]; then
    echo "Stopped: this folder's test is still installed. \"bash controller.sh after\" removes it."
    exit 1
  elif [ "$found" = 1 ]; then
    echo "Stopped: Remote Display was already on this Mac. Tell Claude what's listed above."
    exit 1
  fi
  snapshot > "$DIR/before.txt"
  mv "$DIR/RemoteDisplay.app" /Applications/ || exit 1
  # AirDrop quarantines the app; this build isn't notarized, so Gatekeeper would block it.
  xattr -dr com.apple.quarantine "$APP"
  date > "$MARK"
  echo "Saved what was here in $DIR/before.txt and moved RemoteDisplay to /Applications."
  echo "Open it from Applications, or with the test card as a camera:"
  echo "  open \"$APP\" --args --camera-test-pattern"
  ;;
after)
  if [ ! -f "$DIR/before.txt" ] || [ ! -f "$MARK" ]; then
    echo "Nothing removed: this folder has no test installed. \"bash controller.sh before\" comes first."
    exit 1
  fi
  osascript -e "quit app id \"$ID\"" 2>/dev/null
  sleep 2
  pkill -f "$APP/Contents/MacOS/" 2>/dev/null
  # tccutil finds the app through Launch Services, so reset before deleting it.
  [ -d "$APP" ] && tccutil reset All "$ID"
  defaults delete "$ID" 2>/dev/null
  left=0
  for p in "${OURS[@]}"; do
    [ -e "$p" ] && rm -rf "$p" && echo "removed $p"
    [ -e "$p" ] && { echo "STILL HERE: $p"; left=1; }
  done
  snapshot > "$DIR/after.txt"
  echo "== What differs from before (nothing below this line means all clean):"
  diff "$DIR/before.txt" "$DIR/after.txt"
  echo "== Check by hand in System Settings > Privacy & Security: Camera and Microphone"
  echo "   should no longer list RemoteDisplay. Local Network may keep an entry; macOS has"
  echo "   no reset for it."
  if [ "$left" = 1 ]; then
    echo "== Something above is still here. Run \"bash controller.sh after\" again."
  else
    rm -f "$MARK"
  fi
  ;;
*)
  echo "usage: $0 before|after"; exit 2
  ;;
esac
