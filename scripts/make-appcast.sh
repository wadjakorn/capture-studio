#!/bin/bash
# Generate dist/appcast.xml (Sparkle update feed) for a release .dmg, signed
# with the Sparkle EdDSA private key.
#
# Usage:
#   scripts/make-appcast.sh dist/CaptureStudio-0.3.0.dmg
#
# Key source:
#   - local: the login keychain (created once by Sparkle's generate_keys)
#   - CI:    SPARKLE_PRIVATE_KEY env (export with: generate_keys -x key.txt)
#
# The app reads the feed from SUFeedURL =
#   https://github.com/wadjakorn/capture-studio/releases/latest/download/appcast.xml
# so upload dist/appcast.xml as an asset of the same GitHub Release. Only a
# published, non-prerelease release counts as "latest".
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
[[ -f "$DMG" && "$DMG" == *.dmg ]] || { echo "usage: $0 dist/CaptureStudio-X.Y.Z.dmg" >&2; exit 1; }

BIN=".build/artifacts/sparkle/Sparkle/bin"
[[ -x "$BIN/generate_appcast" ]] || swift package resolve >/dev/null
[[ -x "$BIN/generate_appcast" ]] || { echo "error: $BIN/generate_appcast missing" >&2; exit 1; }

REPO="${GITHUB_REPOSITORY:-wadjakorn/capture-studio}"
VERSION="$(basename "$DMG" .dmg)"; VERSION="${VERSION#CaptureStudio-}"
TAG="v$VERSION"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/"

ARGS=(
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/"
    --link "https://github.com/$REPO/releases/tag/$TAG"
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG"
)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$STAGE"
else
    "$BIN/generate_appcast" "${ARGS[@]}" "$STAGE"
fi

cp "$STAGE/appcast.xml" dist/appcast.xml
echo "Wrote dist/appcast.xml ($TAG)"
