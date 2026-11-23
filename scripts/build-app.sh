#!/bin/bash
# Builds CaptureStudio.app from the SPM executable (no Xcode.app required).
# Usage: scripts/build-app.sh [debug|release]
#
# Env:
#   CS_SIGN_IDENTITY  codesign identity. Default "Capture Studio Dev" (local
#                     self-signed). For distribution use the Developer ID, e.g.
#                     "Developer ID Application: Your Name (TEAMID)".
#                     "-" forces ad-hoc.
#   CS_UNIVERSAL=1    build arm64 + x86_64 (universal) instead of host arch.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
if [[ "${CS_UNIVERSAL:-0}" == "1" ]]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi

BIN="$BIN_DIR/CaptureStudio"
APP="dist/CaptureStudio.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/CaptureStudio"

# Copy SwiftPM resource bundles (e.g. KeyboardShortcuts_KeyboardShortcuts.bundle)
# into Contents/Resources. Without them, Bundle.module can't resolve and the app
# fatalErrors at launch the moment the hotkey recorder view renders.
shopt -s nullglob
for bundle in "$(dirname "$BIN")"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Stamp a monotonic build number (git commit count) into the packaged plist.
# Marketing version (CFBundleShortVersionString) is managed by bump-version.sh.
# Skipped outside a git checkout (e.g. source tarball) — the plist value stands.
if BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist"
fi
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "Version $VERSION (build ${BUILD_NUM:-unknown})"

# Signing. Every identity gets Hardened Runtime + entitlements so local builds
# behave like the notarized release (a missing entitlement shows up here, not
# on a user's Mac). Developer ID builds also get a secure timestamp, which
# notarization requires.
#
# The default self-signed identity keeps TCC (Screen Recording) grants stable
# across rebuilds. Falls back to ad-hoc if it is missing from the keychain.
#
# NOTE: no -v on find-identity. A freshly-imported, untrusted self-signed cert
# (e.g. on a CI runner) is omitted by `find-identity -v` ("valid only") but is
# perfectly usable for signing — codesign needs only the cert + private key, not
# a trust setting. With -v, CI silently fell back to ad-hoc and TCC grants died.
IDENTITY="${CS_SIGN_IDENTITY:-Capture Studio Dev}"
ENTITLEMENTS="Resources/CaptureStudio.entitlements"
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
    if [[ "$IDENTITY" == Developer\ ID* ]]; then
        echo "error: '$IDENTITY' not found in keychain" >&2
        exit 1
    fi
    echo "warning: '$IDENTITY' cert not found; ad-hoc signing (TCC will re-prompt)" >&2
    IDENTITY="-"
fi

TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == Developer\ ID* ]] && TIMESTAMP="--timestamp"

# Sign nested bundles inside-out (never --deep: it applies the app's
# entitlements to everything and Apple discourages it).
shopt -s nullglob
for nested in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Resources/*.bundle; do
    codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$nested"
done
shopt -u nullglob
codesign --force --options runtime "$TIMESTAMP" \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Signed with: $IDENTITY"

echo "Built $APP"
echo "Run with: open $APP"
