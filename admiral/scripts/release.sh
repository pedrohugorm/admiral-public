#!/usr/bin/env bash
#
# Build a Release Admiral.app, sign it, and install it to /Applications.
#
# This is the "official install on this Mac" path (Tier 1): an optimized Release
# build, signed with the local identity from scripts/make-signing-cert.sh. Built
# locally and copied in, it carries no quarantine flag so it just launches — no
# Apple Developer account / notarization needed. (For a portable, Gatekeeper-clean
# app you'd need Developer ID signing + notarization.)
#
# Signing with that one certificate — rather than ad-hoc — is what stops macOS
# re-asking for permissions after every install: see scripts/sign-app.sh.
#
# Your terminals are NOT lost: the open-session list, appearance, theme (UserDefaults
# under com.pedro.admiral), and each claude session's transcript (~/.claude) all live
# outside the app bundle, so the new build reads them back and resumes every session. A
# claude task running at quit-time is interrupted, so stop at a good point first.
#
# Usage:
#   scripts/release.sh            # build + install as the last released version (newest vX.Y.Z tag)
#   scripts/release.sh 1.1        # stamp MARKETING_VERSION = 1.1 instead
#   (the build number is always stamped: CURRENT_PROJECT_VERSION = git commit count)
#   Published releases are made by scripts/release-local.sh (see docs/releasing.md).
#
#   ADMIRAL_INSTALL_DEST=/tmp/x/Admiral.app scripts/release.sh
#                                 # install somewhere else — used to exercise the whole
#                                 # script without replacing the copy that is running
#
set -euo pipefail

cd "$(dirname "$0")/.."   # → admiral/

APP_NAME="Admiral"
SCHEME="Admiral"
PROJ="App/Admiral.xcodeproj"
DERIVED="App/build"
PRODUCT="$DERIVED/Build/Products/Release/$APP_NAME.app"
DEST="${ADMIRAL_INSTALL_DEST:-/Applications/$APP_NAME.app}"
REAL_DEST="/Applications/$APP_NAME.app"
VERSION="${1:-$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

# 1. Fast headless gate: AdmiralCore logic (~0.2s). Catch regressions before a long build.
step "Testing AdmiralCore (swift test)"
swift test

# 2. Regenerate the xcodeproj (it's gitignored; project.yml is source of truth) and
#    build Release.
step "Generating project"
( cd App && xcodegen generate )

step "Building Release"
# Build number (CFBundleVersion) = commits reachable from HEAD: it rises with every commit, so
# each upload outranks the last (App Store Connect refuses a repeat), and a commit always
# builds the same number. project.yml's "1" is only the default for dev builds.
BUILD_NUMBER="$(git rev-list --count HEAD)"
BUILD_SETTINGS=(CODE_SIGNING_ALLOWED=NO "CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
[ -n "$VERSION" ] && BUILD_SETTINGS+=("MARKETING_VERSION=$VERSION")
# CI has nobody to click Xcode's one-time "trust this package plugin/macro" prompt (SwiftTerm
# ships a build plugin), so it skips that validation; on a Mac the prompt was answered once.
XCODEBUILD_FLAGS=()
[ -n "${CI:-}" ] && XCODEBUILD_FLAGS=(-skipPackagePluginValidation -skipMacroValidation)
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" ${XCODEBUILD_FLAGS[@]+"${XCODEBUILD_FLAGS[@]}"} build "${BUILD_SETTINGS[@]}"

# 3. Sign the whole bundle (helpers included) with the stable local identity.
step "Signing"
./scripts/sign-app.sh "$PRODUCT"

# 4. Quit a running instance before clobbering it (sessions resume on relaunch).
#    Match on the executable path: `pgrep -x Admiral` never matches, because the app
#    is execed by full path, so the old guard silently fell through and `rm -rf` ran
#    against a live bundle — leaving an app whose executable is newer than its own
#    _CodeSignature, i.e. "Sealed Resources=none" and no working permission grants.
RUNNING="$APP_NAME.app/Contents/MacOS/$APP_NAME"
if [ "$DEST" = "$REAL_DEST" ] && pgrep -f "$RUNNING" >/dev/null; then
  step "Quitting the running Admiral"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6; do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.5; done
  pkill -f "$RUNNING" 2>/dev/null || true
  sleep 1
fi

# 5. Install and strip any quarantine flag (so it launches without a Gatekeeper prompt).
step "Installing to $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$PRODUCT" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

step "Verifying the installed signature"
codesign --verify --deep --strict "$DEST"
codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => /  designated => /p'

SHORT=$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$DEST/Contents/Info.plist" CFBundleVersion)
printf '\n\033[1;32m✓ Installed Admiral %s (build %s)\033[0m\n' "$SHORT" "$BUILD"
echo "Launch: open -a $APP_NAME"
