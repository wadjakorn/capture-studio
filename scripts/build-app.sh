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

# Stamp a monotonic build number (git commit count) into the packaged plist.
# Marketing version (CFBundleShortVersionString) is managed by bump-version.sh.
# Skipped outside a git checkout (e.g. source tarball) — the plist value stands.
if BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist"
fi
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "Version $VERSION (build ${BUILD_NUM:-unknown})"

# Sign with the stable self-signed cert so TCC permissions survive rebuilds.
# Falls back to ad-hoc if the cert is missing from the keychain.
#
# NOTE: no -v on find-identity. A freshly-imported, untrusted self-signed cert
# (e.g. on a CI runner) is omitted by `find-identity -v` ("valid only") but is
# perfectly usable for signing — codesign needs only the cert + private key, not
# a trust setting. With -v, CI silently fell back to ad-hoc and TCC grants died.
IDENTITY="Capture Studio Dev"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: '$IDENTITY' cert not found; ad-hoc signing (TCC will re-prompt)" >&2
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run with: open $APP"
