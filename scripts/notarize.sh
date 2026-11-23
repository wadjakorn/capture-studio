#!/bin/bash
# Notarize + staple a Developer ID signed .app or .dmg.
#
# Usage:
#   scripts/notarize.sh dist/CaptureStudio.app
#   scripts/notarize.sh dist/CaptureStudio-0.3.0.dmg     # signs the dmg first
#
# Credentials (first match wins):
#   1. App Store Connect API key (CI):
#        APPLE_API_KEY_PATH=/path/AuthKey_XXXX.p8 APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER=<uuid>
#   2. notarytool keychain profile (local). Default name "notary"; override
#      with NOTARY_PROFILE. Create once with:
#        xcrun notarytool store-credentials notary \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw>
#
# Env:
#   CS_SIGN_IDENTITY  Developer ID identity used to sign a .dmg (required for .dmg).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"
[[ -e "$TARGET" ]] || { echo "usage: $0 <path/to/App.app | path/to/file.dmg>" >&2; exit 1; }

if [[ -n "${APPLE_API_KEY_PATH:-}" ]]; then
    : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID required with APPLE_API_KEY_PATH}"
    : "${APPLE_API_ISSUER:?APPLE_API_ISSUER required with APPLE_API_KEY_PATH}"
    AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
    AUTH=(--keychain-profile "${NOTARY_PROFILE:-notary}")
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$TARGET" in
    *.app)
        # Notarization rejects anything not Developer ID signed with Hardened
        # Runtime + timestamp, so fail fast with a readable message.
        if ! codesign -dvv "$TARGET" 2>&1 | grep -q "^Authority=Developer ID Application"; then
            echo "error: $TARGET is not Developer ID signed." >&2
            echo "       rebuild: CS_SIGN_IDENTITY=\"Developer ID Application: NAME (TEAMID)\" scripts/build-app.sh release" >&2
            exit 1
        fi
        SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
        # ditto --keepParent preserves the bundle structure and symlinks.
        ditto -c -k --keepParent "$TARGET" "$SUBMIT"
        ;;
    *.dmg)
        : "${CS_SIGN_IDENTITY:?CS_SIGN_IDENTITY (Developer ID Application) required to sign the dmg}"
        codesign --force --timestamp --sign "$CS_SIGN_IDENTITY" "$TARGET"
        SUBMIT="$TARGET"
        ;;
    *)
        echo "error: expected .app or .dmg, got $TARGET" >&2
        exit 1
        ;;
esac

echo "Submitting $(basename "$SUBMIT") to Apple notary service (usually 1-5 min)..."
OUT="$WORK/result.json"
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json | tee "$OUT"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$OUT" 2>/dev/null || echo unknown)"
ID="$(/usr/bin/plutil -extract id raw -o - "$OUT" 2>/dev/null || echo "")"

if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization status: $STATUS" >&2
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    exit 1
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Final Gatekeeper check, as a downloaded copy would be judged.
if [[ "$TARGET" == *.app ]]; then
    spctl --assess --type execute --verbose=2 "$TARGET"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
echo "Notarized + stapled: $TARGET"
