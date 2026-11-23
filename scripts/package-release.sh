#!/bin/bash
# Build, sign, notarize and package a public release locally:
#   .app (Developer ID + Hardened Runtime) -> notarize + staple
#   -> .dmg -> sign + notarize + staple
#
# Usage:
#   CS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" scripts/package-release.sh
#
# Credentials for notarization: see scripts/notarize.sh (keychain profile
# "notary" locally, App Store Connect API key in CI).
# Set CS_UNIVERSAL=1 for an arm64 + x86_64 build.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CS_SIGN_IDENTITY:?set CS_SIGN_IDENTITY to your Developer ID Application identity (security find-identity -v -p codesigning)}"
[[ "$CS_SIGN_IDENTITY" == Developer\ ID\ Application* ]] || {
    echo "error: CS_SIGN_IDENTITY must be a 'Developer ID Application: ...' identity" >&2; exit 1; }
export CS_SIGN_IDENTITY

scripts/build-app.sh release
scripts/notarize.sh dist/CaptureStudio.app
scripts/make-dmg.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/CaptureStudio.app/Contents/Info.plist)"
scripts/notarize.sh "dist/CaptureStudio-$VERSION.dmg"
shasum -a 256 "dist/CaptureStudio-$VERSION.dmg"
