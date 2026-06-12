#!/bin/bash
# Builds CaptureStudio.app from the SPM executable (no Xcode.app required).
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/CaptureStudio"
APP="dist/CaptureStudio.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/CaptureStudio"

# Sign with the stable self-signed cert so TCC permissions survive rebuilds.
# Falls back to ad-hoc if the cert is missing from the login keychain.
IDENTITY="Capture Studio Dev"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: '$IDENTITY' cert not found; ad-hoc signing (TCC will re-prompt)" >&2
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run with: open $APP"
