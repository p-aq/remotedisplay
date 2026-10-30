#!/bin/bash
# Remote Display live-session test (../README.md), on the build Mac before a build with
# Remote Display Camera: checks the two provisioning profiles from the developer portal
# against what server-mac/Makefile signs (decision 0019). macOS only refuses a wrong
# profile once the app launches or the extension activates, on the host.
#
#   bash profiles.sh TEAM_ID server.provisionprofile camera.provisionprofile [HOST_UDID...]
#
# Each profile must be a macOS profile of TEAM_ID for its App ID, unexpired, with the
# entitlements the build claims and the certificate server-mac/sign-identity.sh picks for
# TEAM_ID. A development profile must also list every Mac that will host: give each one's
# Provisioning UDID (System Information › Hardware), or none when this Mac hosts.
# SIGN_ID= checks that identity instead of sign-identity.sh's pick, as the Makefile would.
# Exit 0 when nothing fails.
set -u
if [ $# -lt 3 ]; then
  echo "usage: $0 TEAM_ID server.provisionprofile camera.provisionprofile [HOST_UDID...]"
  exit 2
fi
TEAM=$1 APP_PROFILE=$2 EXT_PROFILE=$3
shift 3
HOSTS=("$@")
[ ${#HOSTS[@]} -gt 0 ] || HOSTS=("$(system_profiler SPHardwareDataType | sed -n 's/.*Provisioning UDID: //p')")
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
warn() { echo "  WARN $*"; }
get() { /usr/libexec/PlistBuddy -c "Print :$1" "$TMP/p.plist" 2>/dev/null; }

SIGN_ID="${SIGN_ID:-$(bash "$REPO/server-mac/sign-identity.sh" "$TEAM")}"
if [ -n "$SIGN_ID" ]; then
  echo "Signing identity for team $TEAM: $SIGN_ID"
  HASHES=$(security find-identity -v -p codesigning | awk -v n="\"$SIGN_ID\"" 'index($0, n) {print $2}')
else
  echo "FAIL no signing identity of team $TEAM in the keychain (server-mac/sign-identity.sh)"
  fails=1
  HASHES=
fi

# $1 = profile, $2 = its App ID without the team, $3 = 1 if it must allow installing
# system extensions
check() {
  local app_id="$TEAM.$2" expires now certs i h found=0 udid
  echo "$1:"
  if ! security cms -D -i "$1" > "$TMP/p.plist" 2>/dev/null; then
    fail "can't read it as a provisioning profile"
    return
  fi
  if [ "$(get TeamIdentifier:0)" = "$TEAM" ]; then pass "team $TEAM"
  else fail "team $(get TeamIdentifier:0), not $TEAM"; fi
  if get Platform | grep -q '^ *OSX$'; then pass "macOS"
  else fail "not a macOS profile"; fi
  if [ "$(get Entitlements:com.apple.application-identifier)" = "$app_id" ]; then pass "App ID $app_id"
  else fail "App ID $(get Entitlements:com.apple.application-identifier), not $app_id"; fi
  expires=$(plutil -extract ExpirationDate raw -o - "$TMP/p.plist")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ "$expires" > "$now" ]]; then pass "expires $expires"
  else fail "expired $expires"; fi
  if [ "$3" = 1 ]; then
    if [ "$(get Entitlements:com.apple.developer.system-extension.install)" = true ]; then
      pass "allows installing system extensions"
    else
      fail "doesn't allow installing system extensions: turn on System Extension for the App ID"
    fi
  fi
  # macOS doesn't require a team-prefixed app group to be in the profile, but a profile
  # whose App ID has App Groups on lists TEAM_ID.* (Apple DTS, forum thread 721701).
  if get Entitlements:com.apple.security.application-groups | grep -q -x -e " *$TEAM\.\*" -e " *$TEAM\.app\.remotedisplay\.server"; then
    pass "app group $TEAM.app.remotedisplay.server"
  else
    warn "doesn't list $TEAM.* as an app group: turn on App Groups for the App ID"
  fi
  if [ "$(plutil -extract ProvisionsAllDevices raw -o - "$TMP/p.plist" 2>/dev/null)" = true ]; then
    pass "any Mac (Developer ID)"
  else
    for udid in "${HOSTS[@]}"; do
      if get ProvisionedDevices | grep -q -x " *$udid"; then pass "lists host $udid"
      else fail "doesn't list host $udid: register it under Devices and regenerate the profile"; fi
    done
  fi
  [ -n "$SIGN_ID" ] || return
  certs=$(plutil -extract DeveloperCertificates raw -o - "$TMP/p.plist" 2>/dev/null || echo 0)
  for ((i = 0; i < certs; i++)); do
    h=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$TMP/p.plist" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')
    grep -q -x "$h" <<< "$HASHES" && found=1
  done
  if [ "$found" = 1 ]; then pass "includes the certificate of $SIGN_ID"
  else fail "doesn't include the certificate of $SIGN_ID: regenerate it with that one, or set SIGN_ID"; fi
}

check "$APP_PROFILE" app.remotedisplay.server 1
check "$EXT_PROFILE" app.remotedisplay.server.camera 0
if [ "$fails" = 0 ]; then
  echo "PASS. Build with:"
  echo "  make -C \"$REPO/server-mac\" sign ENGINE_BIN=\"$REPO/engine/rustdesk/target/release/rustdesk\" \\"
  echo "    TEAM_ID=$TEAM SIGN_ID=\"$SIGN_ID\" APP_PROFILE=\"$(cd "$(dirname "$APP_PROFILE")" && pwd)/$(basename "$APP_PROFILE")\" \\"
  echo "    EXT_PROFILE=\"$(cd "$(dirname "$EXT_PROFILE")" && pwd)/$(basename "$EXT_PROFILE")\""
else
  echo "FAIL: $fails problem(s) above"
fi
[ "$fails" = 0 ]
