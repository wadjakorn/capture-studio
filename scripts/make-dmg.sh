#!/bin/bash
# Builds dist/CaptureStudio-X.Y.Z.dmg with the classic drag-to-Applications
# installer layout (app icon on the left, Applications symlink on the right).
#
# Prereqs:
#   brew install create-dmg          # the layout tool
#   scripts/build-app.sh release     # build the .app first
#
# IMPORTANT: for public distribution the .app inside MUST be Developer ID signed
# and notarized BEFORE this step. A pretty DMG does not satisfy Gatekeeper —
# an unsigned app inside still gets blocked on other Macs. Unsigned DMGs are
# fine for local testing only.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CaptureStudio.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run scripts/build-app.sh release first" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg missing — brew install create-dmg" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="dist/CaptureStudio-$VERSION.dmg"
rm -f "$DMG"

ARGS=(
    --volname "Capture Studio"
    --window-size 660 400
    --icon-size 128
    --icon "CaptureStudio.app" 165 200
    --app-drop-link 495 200
    --no-internet-enable
)
# Optional custom background like the example (drop a PNG here, ~1320x800 for retina).
[[ -f Resources/dmg-bg.png ]] && ARGS+=(--background Resources/dmg-bg.png)

create-dmg "${ARGS[@]}" "$DMG" "$APP"
echo "Built $DMG"
