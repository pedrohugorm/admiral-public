#!/usr/bin/env bash
#
# Sign an Admiral.app bundle with the stable local identity — the single place
# any build path signs, so every build produces the SAME designated requirement.
#
# That sameness is the whole point. macOS files each privacy grant (App Data,
# Automation, Files & Folders) under the app's designated requirement; ad-hoc
# signing produces none, so TCC falls back to the executable's hash and forgets
# every grant the moment the app is rebuilt. Signing with one certificate pins
# the requirement to `identifier "com.pedro.admiral" and certificate leaf = H"…"`,
# which is identical across rebuilds — grant once, keep it.
#
# Run scripts/make-signing-cert.sh once first to create the identity. Without it
# this falls back to ad-hoc so a fresh clone still builds, and says what that costs.
#
# Usage: scripts/sign-app.sh path/to/Admiral.app
#
set -euo pipefail

APP="${1:?usage: sign-app.sh <path-to-Admiral.app>}"
BUNDLE_ID="com.pedro.admiral"
DEVID_NAME="${ADMIRAL_SIGN_ID:-}"
LOCAL_NAME="Admiral Local Signing"

# Identity preference (first that exists; never silently ad-hoc):
#   1. $ADMIRAL_SIGN_ID   explicit choice (must exist, else this fails). Export it from your shell rc:
#        export ADMIRAL_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)"
#   2. $DEVID_NAME (the same identity)
#        Team ID → Keychain items get a `teamid:<TEAM_ID>` partition that is IDENTICAL on every
#        rebuild (no "wants to use your confidential information" prompts), and the build can be
#        notarized (scripts/notarize.sh) for a Gatekeeper-clean app.
#   3. "Admiral Local Signing"  self-signed: stable DR but NO Team ID → Keychain prompts per rebuild
#   4. ad-hoc only with ADMIRAL_ALLOW_ADHOC=1
# See docs/signing.md.
have() { security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$1\""; }
IDENTITY=""
if [ -n "${ADMIRAL_SIGN_ID:-}" ]; then
  have "$ADMIRAL_SIGN_ID" || security find-certificate -c "$ADMIRAL_SIGN_ID" >/dev/null 2>&1 \
    || { echo "ADMIRAL_SIGN_ID='$ADMIRAL_SIGN_ID' not found in the keychain" >&2; exit 1; }
  IDENTITY="$ADMIRAL_SIGN_ID"
elif have "$DEVID_NAME"; then
  IDENTITY="$DEVID_NAME"
elif security find-certificate -c "$LOCAL_NAME" >/dev/null 2>&1; then
  IDENTITY="$LOCAL_NAME"
elif [ "${ADMIRAL_ALLOW_ADHOC:-}" = 1 ]; then
  IDENTITY="-"
  echo "⚠️  ADMIRAL_ALLOW_ADHOC=1 — ad-hoc signature: every permission is re-asked after each rebuild." >&2
else
  cat >&2 <<ERR
✗ no signing identity found ('$DEVID_NAME' or '$LOCAL_NAME').
  Install the Developer ID cert, or run scripts/make-signing-cert.sh, or set ADMIRAL_ALLOW_ADHOC=1
  to knowingly sign ad-hoc (every permission is re-asked after each rebuild).
ERR
  exit 1
fi
echo "signing identity: $IDENTITY" >&2

# Developer ID builds get the hardened runtime + a secure timestamp (required for notarization).
# The runtime itself needs no entitlements (PTYs/shells, no JIT, no Apple events, no dlopen of
# third-party code); the only one Admiral may claim is the keychain group below.
# ADMIRAL_NO_TIMESTAMP=1 signs offline (--timestamp=none).
OPTS=(--timestamp=none)
case "$IDENTITY" in
  "Developer ID Application:"*)
    if [ "${ADMIRAL_NO_TIMESTAMP:-}" = 1 ]; then OPTS=(--options runtime --timestamp=none)
    else OPTS=(--options runtime --timestamp); fi ;;
esac

# Keychain access group (docs/signing.md → "Keychain access group"). When this Mac has a Developer ID
# provisioning profile for com.pedro.admiral, it is embedded and authorizes App/Admiral.entitlements
# (keychain-access-groups): the app's secrets then live in the data-protection keychain. Without
# one nothing is claimed — macOS refuses to run code claiming that unprofiled — and the app keeps
# its secrets in the login keychain. Helpers never get it.
ADMIRAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${ADMIRAL_PROVISIONING_PROFILE:-$ADMIRAL_DIR/App/Admiral.provisionprofile}"
APP_OPTS=()
rm -f "$APP/Contents/embedded.provisionprofile"
if [ -f "$PROFILE" ]; then
  case "$IDENTITY" in
    "Developer ID Application:"*)
      DECODED="$(mktemp)"
      security cms -D -i "$PROFILE" -o "$DECODED"
      APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$DECODED" 2>/dev/null || true)"
      TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$DECODED" 2>/dev/null || true)"
      rm -f "$DECODED"
      [ -n "$TEAM_ID" ] && [ "$APP_ID" = "$TEAM_ID.$BUNDLE_ID" ] \
        || { echo "✗ $PROFILE is for '${APP_ID:-another platform}', not <team id>.$BUNDLE_ID" >&2; exit 1; }
      cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
      # The entitlements file is a template; the team id comes from the profile, not from the repo.
      ENTITLEMENTS="$(mktemp)"
      sed "s/__TEAM_ID__/$TEAM_ID/g" "$ADMIRAL_DIR/App/Admiral.entitlements" > "$ENTITLEMENTS"
      trap 'rm -f "$ENTITLEMENTS"' EXIT
      APP_OPTS=(--entitlements "$ENTITLEMENTS")
      echo "provisioning profile: $PROFILE → keychain access group" >&2 ;;
    *) echo "⚠️  $PROFILE ignored: it needs the Developer ID identity, not '$IDENTITY' (login keychain)" >&2 ;;
  esac
fi

# Inside-out: nested code first, because signing the bundle seals whatever the
# helpers currently are. Re-signing a helper afterwards would break that seal —
# which is exactly how the installed copy ended up with "Sealed Resources=none".
# Notarization rejects ANY unsigned/untimestamped Mach-O in the bundle, not just Contents/Helpers:
# the xcodegen tool-target dependencies also drop copies of the helpers into Contents/Resources,
# so sign every nested Mach-O (Helpers, Resources, Frameworks, PlugIns), not a fixed folder.
while IFS= read -r -d '' helper; do
  case "$(file -b "$helper")" in
    *Mach-O*) codesign --force "${OPTS[@]}" --sign "$IDENTITY" "$helper" ;;
  esac
done < <(find "$APP/Contents" -type f ! -path "$APP/Contents/MacOS/*" -print0)

codesign --force "${OPTS[@]}" ${APP_OPTS[@]+"${APP_OPTS[@]}"} --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "signature OK — designated requirement:"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
