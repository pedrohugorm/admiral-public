#!/usr/bin/env bash
#
# Wrap a notarized, stapled Admiral.app in the installer people download: a drag-to-Applications
# DMG, signed with the same Developer ID identity, then notarized + stapled itself
# (scripts/notarize.sh), so it opens without a Gatekeeper warning even offline.
#
# Usage: scripts/make-dmg.sh path/to/Admiral.app path/to/Admiral-1.2.0.dmg
#
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Admiral.app> <output.dmg>}"
DMG="${2:?usage: make-dmg.sh <Admiral.app> <output.dmg>}"
IDENTITY="${ADMIRAL_SIGN_ID:?set ADMIRAL_SIGN_ID to your \"Developer ID Application: <Name> (<TEAM_ID>)\" identity}"

# Notarize the app first: the stapled ticket inside is what lets it launch offline once copied out.
xcrun stapler validate "$APP" >/dev/null \
  || { echo "✗ $APP has no stapled ticket — run scripts/notarize.sh on it first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Admiral.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Admiral -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
"$(dirname "$0")/notarize.sh" "$DMG"
