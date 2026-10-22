#!/usr/bin/env bash
#
# Notarize and staple a Developer-ID-signed Admiral.app — or the DMG scripts/make-dmg.sh wraps it
# in — so it is Gatekeeper-clean and portable to other Macs.
#
# Prerequisites (one time, by you — this script never creates credentials):
#   xcrun notarytool store-credentials admiral-notary \
#       --apple-id <your apple id> --team-id <TEAM_ID> --password <app-specific password>
#   (create the app-specific password at appleid.apple.com → Sign-In and Security)
#
# The app must be signed with the Developer ID identity + hardened runtime + secure timestamp:
# scripts/sign-app.sh does exactly that when $ADMIRAL_SIGN_ID names a
# "Developer ID Application: <Name> (<TEAM_ID>)" identity in the keychain.
#
# Usage: scripts/notarize.sh [path/to/Admiral.app | path/to/Admiral.dmg]   (default: /Applications/Admiral.app)
#        ADMIRAL_NOTARY_PROFILE=other-profile scripts/notarize.sh
#        ADMIRAL_NOTARY_KEYCHAIN=<keychain>   read the profile from that keychain (CI)
#
set -euo pipefail

TARGET="${1:-/Applications/Admiral.app}"
PROFILE="${ADMIRAL_NOTARY_PROFILE:-admiral-notary}"
CREDS=(--keychain-profile "$PROFILE")
[ -n "${ADMIRAL_NOTARY_KEYCHAIN:-}" ] && CREDS+=(--keychain "$ADMIRAL_NOTARY_KEYCHAIN")
[ -e "$TARGET" ] || { echo "no such app or disk image: $TARGET" >&2; exit 1; }

# Refuse to upload something Apple will reject anyway.
SIG="$(codesign -dvv "$TARGET" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIG" \
  || { echo "✗ $TARGET is not signed with a Developer ID Application identity" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$TARGET" in
  *.dmg)
    codesign --verify --strict "$TARGET"
    UPLOAD="$TARGET"
    ASSESS=(-t open --context context:primary-signature) ;;
  *)
    codesign --verify --deep --strict "$TARGET"
    grep -q "flags=.*(runtime)" <<<"$SIG" \
      || { echo "✗ $TARGET lacks the hardened runtime (run scripts/sign-app.sh)" >&2; exit 1; }
    UPLOAD="$WORK/Admiral.zip"
    echo "▶ zipping $TARGET"
    ditto -c -k --keepParent "$TARGET" "$UPLOAD"
    ASSESS=(-t exec) ;;
esac

echo "▶ submitting to Apple (profile: $PROFILE) — waits for the verdict, usually a few minutes"
OUT="$(xcrun notarytool submit "$UPLOAD" "${CREDS[@]}" --wait 2>&1)" || true
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
  ID="$(sed -n 's/^ *id: *//p' <<<"$OUT" | head -1)"
  echo "✗ notarization not accepted. Log: xcrun notarytool log $ID ${CREDS[*]}" >&2
  exit 1
fi

echo "▶ stapling the ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
spctl -a -vv "${ASSESS[@]}" "$TARGET" || true
echo "done — $TARGET is notarized and stapled"
