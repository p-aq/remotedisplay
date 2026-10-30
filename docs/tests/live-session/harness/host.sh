#!/bin/bash
# Remote Display live-session test (../README.md), on the Mac that hosts. AirDrop it in
# one folder with the server app (server-mac/.build/Remote Display Server.app), then run
# from Terminal there:
#
#   bash host.sh before   notes what's on this Mac, then moves the app to /Applications
#   bash host.sh after    removes only what the test added, and shows what differs
#
# It stops at "before" if Remote Display is already here, so it never deletes
# anything the test didn't add. Remote Display Camera can only be removed by the app
# (Settings › Remove Camera and Microphone), so "after" stops while it's still installed:
# deleting the app first would leave the extension behind.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Remote Display Server.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/RemoteDisplayMicrophone.driver"
ID=app.remotedisplay.server
CAMERA_ID=$ID.camera
OURS=(
  "$APP"
  "$HOME/Library/LaunchAgents/$ID.plist"
  "$HOME/Library/Preferences/RemoteDisplay"
  "$HOME/Library/Preferences/$ID.plist"
  "$HOME/Library/Logs/RemoteDisplayServer"
  "$HOME/Library/Logs/RemoteDisplay"
  "$HOME/Library/Application Support/remotedisplay-forwarding.json"
  "$HOME/Library/Application Support/remotedisplay-perms.json"
  "$HOME/Library/Saved Application State/$ID.savedState"
  "$HOME/Library/Caches/$ID"
  "$HOME/Library/HTTPStorages/$ID"
  "$HOME/Library/HTTPStorages/$ID.binarycookies"
  "/tmp/RemoteDisplay-$(id -u)"
  "/tmp/RemoteDisplay-service"
  "$DRIVER"
)

# Remote Display Camera's states as macOS lists them, one per line: "activated enabled",
# "activated waiting for user", "terminated waiting to uninstall on reboot"; nothing when
# macOS doesn't know it.
camera_states() {
  systemextensionsctl list 2>/dev/null | grep -F "$CAMERA_ID (" | sed -n 's/.*\[\(.*\)\]$/\1/p'
}

snapshot() {
  echo "## system"; sw_vers; uname -m
  for d in ~ ~/Library ~/Library/LaunchAgents ~/Library/Preferences ~/Library/Logs \
      "$HOME/Library/Application Support" "$HOME/Library/Saved Application State" \
      ~/Library/Caches ~/Library/HTTPStorages /Library/Audio/Plug-Ins/HAL /Applications; do
    echo "## $d"; ls -A "$d" 2>&1
  done
  echo "## /tmp RemoteDisplay"; ls -d /tmp/RemoteDisplay* 2>/dev/null
  echo "## system extensions"; systemextensionsctl list 2>&1
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
  for s in $(camera_states | tr ' ' '_'); do
    echo "Already here: Remote Display Camera [${s//_/ }]"; found=1
  done
  if [ "$found" = 1 ]; then
    echo "Stopped: Remote Display was already on this Mac. Tell Claude what's listed above."
    exit 1
  fi
  if lsof -nP -iTCP:21118 -sTCP:LISTEN 2>/dev/null | grep -q .; then
    echo "Stopped: something already listens on port 21118:"; lsof -nP -iTCP:21118 -sTCP:LISTEN
    exit 1
  fi
  snapshot > "$DIR/before.txt"
  mv "$DIR/Remote Display Server.app" /Applications/ || exit 1
  # AirDrop quarantines the app; this build isn't notarized, so Gatekeeper would block it.
  xattr -dr com.apple.quarantine "$APP"
  echo "Moved the app to /Applications. This Mac's addresses:"
  for i in en0 en1 en2; do ip=$(ipconfig getifaddr $i) && echo "  $i $ip"; done
  echo "Saved what was here in $DIR/before.txt. Now open Remote Display Server from Applications."
  ;;
after)
  [ -f "$DIR/before.txt" ] || { echo "No before.txt: run ./host.sh before first"; exit 1; }
  restart=0
  for s in $(camera_states | tr ' ' '_'); do
    case "$s" in
    terminated*) restart=1 ;;
    *)
      echo "Stopped: Remote Display Camera is still installed [${s//_/ }]."
      echo "In Remote Display Server, open Settings and click Remove Camera and Microphone,"
      echo "then run this again. Nothing was removed."
      exit 1
      ;;
    esac
  done
  osascript -e "quit app id \"$ID\"" 2>/dev/null
  sleep 2
  launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
  pkill -f "$APP/Contents/MacOS/" 2>/dev/null
  if [ -e "$DRIVER" ]; then
    echo "Remote Display Microphone is still installed; removing it needs your password:"
    sudo sh -c "rm -rf '$DRIVER' && (killall coreaudiod || true)"
  fi
  # tccutil finds the app through Launch Services, so reset before deleting it.
  [ -d "$APP" ] && tccutil reset All "$ID"
  # cfprefsd would write its cached copy back over a deleted plist.
  defaults delete "$ID" 2>/dev/null
  for p in "${OURS[@]}"; do
    [ -e "$p" ] && rm -rf "$p" && echo "removed $p"
  done
  snapshot > "$DIR/after.txt"
  echo "== What differs from before (nothing below this line means all clean):"
  diff "$DIR/before.txt" "$DIR/after.txt"
  echo "== Check by hand in System Settings > Privacy & Security: remove any leftover"
  echo "   Remote Display Server or remotedisplayd entry under Screen & System Audio Recording"
  echo "   and Accessibility with the - button. Camera should list neither. Local Network may"
  echo "   keep an entry; macOS has no reset for it."
  if [ "$restart" = 1 ]; then
    echo "== Remote Display Camera finishes uninstalling when this Mac restarts. Restart, then"
    echo "   run \"bash host.sh after\" again: its system extensions should match before.txt."
  fi
  ;;
*)
  echo "usage: $0 before|after"; exit 2
  ;;
esac
