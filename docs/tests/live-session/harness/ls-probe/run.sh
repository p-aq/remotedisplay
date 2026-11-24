#!/bin/bash
# ls-probe (decision 0034; Accessibility: accessibility.sh): does Launch Services count a headless engine inside an app bundle
# as the app? Builds a throwaway bundle (identifier app.example.lsprobe, ad-hoc signed) in a
# temporary folder, with an accessory "app" and a headless "engine" like remotedisplayd. It
# starts the engine through launchd, as the LaunchAgent does, then opens the bundle and sends a
# scripted quit, for three layouts:
#   1. the engine in Contents/MacOS, as today;
#   2. the same, answering open/reopen itself and ignoring quit (--forward);
#   3. the engine in Contents/Helpers.
# For each it prints what started, what the quit reached, and the identity tccd checked for the
# engine's Screen Recording status. It unregisters and deletes the bundle at the end.
set -u
T=$(mktemp -d) B="$T/Dummy.app" L=app.example.lsprobe.engine HERE="$(cd "$(dirname "$0")" && pwd)"
C="$B/Contents"; mkdir -p "$C/MacOS" "$C/Helpers"
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.example.lsprobe</string>
<key>CFBundleExecutable</key><string>app</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>LS Probe</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
D="-DLOGPATH=\"$T/launches.txt\""
xcrun clang -fobjc-arc "$D" -framework AppKit "$HERE/app.m" -o "$C/MacOS/app" || exit 1
xcrun clang -fobjc-arc "$D" -framework AppKit -framework CoreGraphics "$HERE/engine.m" -o "$C/MacOS/engine" || exit 1
cp "$C/MacOS/engine" "$C/Helpers/engine"
codesign -s - -f --identifier app.example.lsprobe "$C/MacOS/engine" "$C/Helpers/engine" 2>/dev/null
codesign -s - -f "$B" 2>/dev/null
run() {
  : > "$T/launches.txt"; local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  launchctl submit -l $L -- "$2" $3; sleep 2
  echo "== $1"
  open "$B"; sleep 3
  echo "   after open: $(tr '\n' ';' < "$T/launches.txt")"
  osascript -e 'tell application id "app.example.lsprobe" to quit' >/dev/null 2>&1; sleep 2
  echo "   after a scripted quit: engine $(pgrep -f "$2" >/dev/null && echo running || echo gone)"
  echo "   tccd's identity: $(/usr/bin/log show --start "$t0" --style compact --predicate 'process == "tccd" AND eventMessage CONTAINS "staticCode" AND eventMessage CONTAINS "lsprobe"' 2>/dev/null | grep -oE 'type: [0-9]+' | sort -u | tr '\n' ' ')(type 0 = the bundle)"
  launchctl remove $L 2>/dev/null; pkill -f "$C/MacOS/app"; sleep 1
}
run "1. engine in Contents/MacOS" "$C/MacOS/engine" ""
run "2. engine in Contents/MacOS, answering open and ignoring quit" "$C/MacOS/engine" "--forward"
run "3. engine in Contents/Helpers" "$C/Helpers/engine" ""
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$B" 2>/dev/null
rm -rf "$T"
