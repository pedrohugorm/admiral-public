#!/usr/bin/env bash
#
# Publish an Admiral release from this Mac. This is the only way releases are made: version from
# scripts/next-version.sh, build number = commit count, Developer ID signing, notarization, a DMG,
# and a GitHub Release with generated notes (see docs/releasing.md).
#
#   scripts/release-local.sh              # version from scripts/next-version.sh, build, publish
#   scripts/release-local.sh 1.4.0        # force a version
#   scripts/release-local.sh --check      # preflight only: say what would be released, build nothing
#   scripts/release-local.sh --no-publish # build + notarize + DMG, leave the DMG, publish nothing
#
# It builds into a temp folder (`ADMIRAL_INSTALL_DEST`), so the Admiral running on this Mac is
# never quit or replaced. Needs: the Developer ID in the keychain (`ADMIRAL_SIGN_ID`),
# App/Admiral.provisionprofile, the `admiral-notary` notarytool profile, an authenticated `gh`.
# Setup for a new Mac: docs/signing.md.
#
set -euo pipefail

cd "$(dirname "$0")/.."   # → admiral/

CHECK=0 PUBLISH=1 VERSION=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --no-publish) PUBLISH=0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) VERSION="$arg" ;;
  esac
done

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight: everything that can be wrong is said before the long build ---------------------

step "Preflight"
git fetch --quiet origin main --tags
git diff --quiet && git diff --cached --quiet || die "uncommitted changes to tracked files — commit or stash first"
# An untracked source file would be built into the release without being in the tagged commit.
[ -z "$(git status --porcelain --untracked-files=all -- .)" ] \
  || die "untracked files inside admiral/ — commit, remove or gitignore them first (git status -- .)"
SHA="$(git rev-parse HEAD)"
[ "$SHA" = "$(git rev-parse origin/main)" ] \
  || die "HEAD ($SHA) is not origin/main — push first: the release tag must point at a pushed commit"
[ -n "$VERSION" ] || VERSION="$(scripts/next-version.sh)"
[ -n "$VERSION" ] || { echo "nothing to release: no feat/fix/perf commit touching admiral/ since the last tag"; exit 0; }
# Checked before its first use: it becomes the tag, a temp path, the DMG name and Info.plist.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not MAJOR.MINOR.PATCH (e.g. 1.4.0)"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
BUILD="$(git rev-list --count HEAD)"
[ "$(git rev-parse --is-shallow-repository)" = false ] || die "shallow clone: the build number would be wrong"
[ -f App/Admiral.provisionprofile ] || die "App/Admiral.provisionprofile is missing (docs/signing.md)"
xcrun notarytool history --keychain-profile admiral-notary >/dev/null 2>&1 \
  || die "no notarytool keychain profile 'admiral-notary' (docs/signing.md)"
if [ "$PUBLISH" = 1 ]; then gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"; fi
echo "release $TAG  build $BUILD  commit ${SHA:0:7}"
[ "$CHECK" = 1 ] && exit 0

# --- Build: test, Release build, sign, notarize, DMG ---------------------------------------------

DIST="$(mktemp -d "${TMPDIR:-/tmp}/admiral-release-$VERSION.XXXXXX")"
APP="$DIST/Admiral.app"
DMG="$DIST/Admiral-$VERSION.dmg"
echo "working in $DIST (kept if anything fails)"

step "Test, build, sign"
ADMIRAL_INSTALL_DEST="$APP" scripts/release.sh "$VERSION"
[ "$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)" = "$BUILD" ] \
  || die "built CFBundleVersion is not $BUILD"

step "Notarize the app"
scripts/notarize.sh "$APP"

step "DMG installer"
scripts/make-dmg.sh "$APP" "$DMG"

if [ "$PUBLISH" = 0 ]; then
  printf '\n\033[1;32m✓ Built %s (not published)\033[0m\n' "$DMG"
  exit 0
fi

# --- Publish: tag + GitHub Release with the DMG ---------------------------------------------------

step "Publish $TAG"
PREV="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
if [ -n "$PREV" ]; then
  NOTES="$(git log "$PREV..HEAD" --format='- %s (%h)' -- . | grep -E '^- (feat|fix|perf)(\(|!|:)' || true)"
else
  NOTES="First release."
fi
gh release create "$TAG" "$DMG" --target "$SHA" --title "Admiral $VERSION (build $BUILD)" --notes "$NOTES"
printf '\n\033[1;32m✓ Released %s (build %s)\033[0m\n' "$TAG" "$BUILD"
rm -rf "$DIST"
