#!/bin/bash
# Cut a release: bump the marketing version in Info.plist, commit, and tag.
# Does NOT push. Mirrors capz's scripts/release.mjs.
#
# Pushing the tag (git push --follow-tags) triggers .github/workflows/build.yml,
# which signs the app, builds the .dmg, and creates a GitHub Release.
#
# Usage:
#   scripts/release.sh patch|minor|major|X.Y.Z [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
PB="/usr/libexec/PlistBuddy"

bump="${1:-}"
[[ -n "$bump" ]] || { echo "usage: $0 patch|minor|major|X.Y.Z [--dry-run]" >&2; exit 1; }
DRY=0
[[ "${2:-}" == "--dry-run" ]] && DRY=1

# Require a clean tree so the only change in the release commit is the bump.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree dirty — commit or stash first" >&2
    exit 1
fi

current="$("$PB" -c "Print :CFBundleShortVersionString" "$PLIST")"
scripts/bump-version.sh "$bump" >/dev/null
new="$("$PB" -c "Print :CFBundleShortVersionString" "$PLIST")"
tag="v$new"

echo "release: $current -> $new  ($tag)"

if [[ "$DRY" -eq 1 ]]; then
    git checkout -- "$PLIST"
    echo "(dry run — reverted, no commit/tag)"
    exit 0
fi

git add "$PLIST"
git commit -m "chore(release): $tag"
git tag "$tag"
echo "done. push with: git push --follow-tags"
