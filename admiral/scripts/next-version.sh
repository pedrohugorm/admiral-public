#!/usr/bin/env bash
#
# The next Admiral release version, from the Conventional Commits since the last vX.Y.Z tag.
# Prints nothing when none of them warrants a release.
#
#   feat!: / fix!: …, or a "BREAKING CHANGE:" footer → major
#   feat:                                          → minor
#   fix: / perf:                                   → patch
#   anything else (docs, chore, ci, test, …)       → no release
#
# Only commits that touch admiral/ count — this repo also holds the iTerm2 bridge and the TUI.
# With no tag yet, the first release is project.yml's MARKETING_VERSION, as X.Y.Z.
#
# Usage: scripts/next-version.sh            (scripts/release-local.sh calls it)
#
set -euo pipefail

cd "$(dirname "$0")/.."   # → admiral/

LAST="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
if [ -z "$LAST" ]; then
  BASE="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\).*/\1/p' App/project.yml | head -1)"
  IFS=. read -r MAJOR MINOR PATCH <<<"$BASE"
  echo "${MAJOR:-1}.${MINOR:-0}.${PATCH:-0}"
  exit 0
fi

SUBJECTS="$(git log "$LAST..HEAD" --format=%s -- .)"
BODIES="$(git log "$LAST..HEAD" --format=%b -- .)"
TYPE='[a-z]+(\([^)]*\))?'
if grep -Eq "^$TYPE!:" <<<"$SUBJECTS" || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$BODIES"; then BUMP=major
elif grep -Eq '^feat(\([^)]*\))?:' <<<"$SUBJECTS"; then BUMP=minor
elif grep -Eq '^(fix|perf)(\([^)]*\))?:' <<<"$SUBJECTS"; then BUMP=patch
else exit 0
fi

IFS=. read -r MAJOR MINOR PATCH <<<"${LAST#v}"
case "$BUMP" in
  major) echo "$((MAJOR + 1)).0.0" ;;
  minor) echo "$MAJOR.$((MINOR + 1)).0" ;;
  patch) echo "$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac
