#!/usr/bin/env bash
#
# Exercises scripts/next-version.sh against a throwaway git repo shaped like this one
# (admiral/ beside other projects). Prints PASS/FAIL per case; exits 1 on any FAIL.
#
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
cd "$REPO"
git init -q
git config user.email test@example.com
git config user.name test
mkdir -p admiral/scripts admiral/App src
cp "$SCRIPT" admiral/scripts/
printf 'settings:\n  base:\n    MARKETING_VERSION: "1.0"\n' > admiral/App/project.yml

FAILED=0
commit() {  # commit <path> <subject> [body]
  echo "$RANDOM" >> "$1"
  git add -A
  git commit -q -m "$2" ${3:+-m "$3"}
}
expect() {  # expect <wanted> <case>
  local got
  got="$(admiral/scripts/next-version.sh)"
  if [ "$got" = "$1" ]; then echo "PASS  $2 → ${1:-(no release)}"
  else echo "FAIL  $2: wanted '${1:-(no release)}', got '${got:-(no release)}'"; FAILED=1; fi
}

commit admiral/a "feat(admiral): first"
expect 1.0.0 "no tag yet → project.yml's version"
git tag v1.0.0

commit admiral/a "docs(admiral): readme"
commit admiral/a "chore(admiral): tidy"
expect "" "docs/chore only"

commit src/x "feat(bridge): outside admiral/"
expect "" "a feat outside admiral/"

commit admiral/a "fix(admiral): a bug"
expect 1.0.1 "fix → patch"

commit admiral/a "perf(admiral): faster"
expect 1.0.1 "perf → patch"

commit admiral/a "feat(admiral): a feature"
expect 1.1.0 "feat → minor (beats fix)"
git tag v1.1.0

commit admiral/a "fix(admiral): with a footer" "BREAKING CHANGE: config moved"
expect 2.0.0 "BREAKING CHANGE footer → major"
git tag v2.0.0

commit admiral/a "feat(admiral)!: new storage"
expect 3.0.0 "! → major"

commit admiral/a "docs(admiral): mention feat: in a body" "feat: this line is only in the body"
expect 3.0.0 "a type in a body doesn't count (still major from before)"
git tag v3.0.0
commit admiral/a "docs(admiral): x" "feat: only in the body"
expect "" "feat: in a body alone releases nothing"

exit "$FAILED"
