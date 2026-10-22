# Releasing

Releases are made by hand from this Mac with `scripts/release-local.sh`. There is no CI release
workflow: pushing to `main` publishes nothing.

1. **Version** — `scripts/next-version.sh` reads the Conventional Commits since the last `vX.Y.Z` tag:
   `feat` → minor, `fix`/`perf` → patch, `!` or a `BREAKING CHANGE:` footer → major. Anything else
   (docs, chore, ci, test) releases nothing, and only commits that touch `admiral/` count. With no tag
   yet, the first release is `project.yml`'s `MARKETING_VERSION`. Tests: `scripts/test-next-version.sh`.
2. **Build number** — `git rev-list --count HEAD`, stamped by `scripts/release.sh`.
3. **Build** — `scripts/release.sh <version>` (swift test, Release build, sign with the Developer ID +
   provisioning profile) into a temp folder, `scripts/notarize.sh` on the app, then
   `scripts/make-dmg.sh`: a drag-to-Applications DMG, signed, notarized and stapled.
4. **Publish** — GitHub Release `vX.Y.Z` with `Admiral-X.Y.Z.dmg`; the notes list the feat/fix commits
   since the previous tag.

`scripts/release-local.sh` runs all four. It refuses to start unless the tree is clean and HEAD is the
pushed `origin/main`, then builds into a temp folder (the Admiral running here is never quit) and runs
`gh release create`.

```bash
scripts/release-local.sh --check      # what would be released, and whether the keys/profile/gh are in place
scripts/release-local.sh              # build, notarize, DMG, publish vX.Y.Z
scripts/release-local.sh --no-publish # stop after the DMG
```

Don't commit between the preflight and the publish: the build number is the commit count.

The signing identity (`ADMIRAL_SIGN_ID`), the provisioning profile and the `admiral-notary` notarytool
profile live on this Mac; see [signing.md](signing.md).

## By hand

`scripts/release.sh` → `scripts/notarize.sh` → `scripts/make-dmg.sh <Admiral.app> <Admiral.dmg>` does the
same on this Mac (`release.sh` installs to /Applications unless `ADMIRAL_INSTALL_DEST` points elsewhere).
