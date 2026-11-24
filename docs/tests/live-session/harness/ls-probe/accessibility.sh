#!/bin/bash
# ls-probe, Accessibility (decision 0034): which identity does tccd use for a launchd-run
# engine's Accessibility, from Contents/Helpers and from Contents/MacOS? One throwaway bundle
# per layout, each with its own identifier so one run's entry can't hide the other's,
# Helpers first. No prompt is shown. Result on 2026-11-23 (macOS 27.2): Helpers →
# identifier_type=Path, MacOS → identifier_type=Bundle ID.
#
# Asking leaves a switched-off Accessibility entry per run. The script resets the bundle-ID
# ones (tccutil only finds apps in /Applications, so the bundles move there for a moment, as
# zz-app.example.axprobe.*.app; an interrupted run removes them too).
# The Helpers run's entry is keyed by a path that is gone by then, which tccutil can't
# reset: remove it in System Settings › Privacy & Security › Accessibility ("engine", "−").
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T=$(mktemp -d)
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
IDS="app.example.axprobe.helpers app.example.axprobe.macos"
cleanup() {
  for id in $IDS; do
    launchctl remove "$id.engine" 2>/dev/null
    for b in "$T/$id.app" "/Applications/zz-$id.app"; do
      [ -d "$b" ] && { "$LSREG" -u "$b"; rm -rf "$b"; }
    done
  done
  rm -rf "$T"
}
trap cleanup EXIT
xcrun clang -fobjc-arc -framework AppKit -framework ApplicationServices "$HERE/ax-engine.m" -o "$T/engine" || exit 1
printf 'int main(void){return 0;}' | xcrun clang -x c - -o "$T/app" || exit 1
bundle() { # bundle <identifier>: builds $T/<identifier>.app, ad-hoc signed
  local B="$T/$1.app"; mkdir -p "$B/Contents/MacOS" "$B/Contents/Helpers"
  cat > "$B/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$1</string>
<key>CFBundleExecutable</key><string>app</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>AX Probe</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
  cp "$T/app" "$B/Contents/MacOS/app"; cp "$T/engine" "$B/Contents/MacOS/engine"; cp "$T/engine" "$B/Contents/Helpers/engine"
  codesign -s - -f --identifier "$1" "$B/Contents/MacOS/engine" "$B/Contents/Helpers/engine" 2>/dev/null
  codesign -s - -f "$B" 2>/dev/null
  "$LSREG" -f "$B"
}
probe() { # probe <identifier> <MacOS|Helpers>
  bundle "$1"; local B="$T/$1.app" t0; t0=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
  launchctl submit -l "$1.engine" -- "$B/Contents/$2/engine" "$T/out.txt"; sleep 4
  launchctl remove "$1.engine" 2>/dev/null; sleep 1
  echo "== engine in Contents/$2: $(grep "/$2/engine" "$T/out.txt" | sed 's/.*: //')"
  /usr/bin/log show --start "$t0" --style compact --predicate "process == \"tccd\" AND eventMessage CONTAINS \"$1\"" 2>/dev/null \
    | grep -oE 'service=kTCCServiceAccessibility, identifier_type=[A-Za-z ]+' | sort -u | sed 's/^/   tccd: /'
}
probe app.example.axprobe.helpers Helpers
probe app.example.axprobe.macos MacOS
for id in $IDS; do
  "$LSREG" -u "$T/$id.app"; mv "$T/$id.app" "/Applications/zz-$id.app" && "$LSREG" -f "/Applications/zz-$id.app"
done
sleep 2
for id in $IDS; do
  tccutil reset All "$id" >/dev/null 2>&1 || echo "Couldn't reset $id's entries (tccutil reset All $id)."
done
echo "Remove the Helpers run's \"engine\" entry by hand: System Settings › Privacy & Security › Accessibility."
