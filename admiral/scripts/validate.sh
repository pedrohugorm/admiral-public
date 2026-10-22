#!/usr/bin/env bash
#
# Admiral local validation — the drive-ticket "local cluster proof" adapted to a
# machine with no remote environment. Every gate produces an artifact under
# .validation/ and the script fails loudly on the first broken gate.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VALID="$ROOT/.validation"
mkdir -p "$VALID"

step() { printf '\n==> %s\n' "$*"; }

step "[1/5] AdmiralCore unit tests (swift test)"
if ! swift test > "$VALID/core-tests.log" 2>&1; then
  tail -30 "$VALID/core-tests.log"
  echo "FAIL: core tests"; exit 1
fi
grep -E "Executed [0-9]+ tests" "$VALID/core-tests.log" | tail -1 || true

step "[2/5] Generate Xcode project (xcodegen)"
( cd App && xcodegen generate ) > "$VALID/xcodegen.log" 2>&1
echo "   project generated"

step "[3/5] Build + rendered-UI tests (xcodebuild test, XCUITest)"
if ! xcodebuild test -project App/Admiral.xcodeproj -scheme Admiral -configuration Debug \
      -derivedDataPath App/build -destination 'platform=macOS' \
      -only-testing:AdmiralUITests \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO > "$VALID/xcodebuild-test.log" 2>&1 \
   || ! grep -q "TEST SUCCEEDED" "$VALID/xcodebuild-test.log"; then
  grep -E "error:|Test Case .* failed" "$VALID/xcodebuild-test.log" | tail -30
  echo "FAIL: build / UI tests"; exit 1
fi
grep -E "Test Case .* passed" "$VALID/xcodebuild-test.log" | sed -E 's/.*Tests\.//; s/ \(.*//' | sed 's/^/   ok: /'

APP="App/build/Build/Products/Debug/Admiral.app"
codesign --force --deep --sign - "$APP" > /dev/null 2>&1

step "[4/5] Render UI snapshot (ImageRenderer)"
rm -f "$VALID/ui.png"
ADMIRAL_SNAPSHOT="$VALID/ui.png" "$APP/Contents/MacOS/Admiral" > /dev/null 2>&1 || true
if [ ! -s "$VALID/ui.png" ]; then
  echo "FAIL: UI snapshot not produced"; exit 1
fi
echo "   wrote $VALID/ui.png ($(stat -f%z "$VALID/ui.png") bytes)"

step "[5/5] Install to /Applications (stable path for the real icon)"
DST="/Applications/Admiral.app"
rm -rf "$DST"; cp -R "$APP" "$DST"
codesign --force --deep --sign - "$DST" > /dev/null 2>&1
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -f "$DST" > /dev/null 2>&1 || true
echo "   installed $DST"

printf '\nAll gates passed. Artifacts in %s\n' "$VALID"
