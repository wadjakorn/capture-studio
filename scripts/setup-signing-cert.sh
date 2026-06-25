#!/usr/bin/env bash
# One-time setup: generate a FREE self-signed macOS code-signing certificate
# and push it (plus password + identity name) to this repo's GitHub Actions
# secrets so CI signs every release with a STABLE code identity.
#
# Why: ad-hoc signing ("-") gives a new cdhash every build, so macOS keys the
# Screen Recording (TCC) grant to that hash and the permission dies on every
# rebuild / update. A stable self-signed identity makes the grant survive.
# The identity name MUST match build-app.sh's IDENTITY ("Capture Studio Dev").
#
# This does NOT notarize and does NOT remove the Gatekeeper "unverified
# developer" prompt on a direct .dmg download. Homebrew install strips the
# quarantine flag so the brew path is clean. Only a paid Apple Developer ID +
# notarization removes the prompt for direct downloads (see RELEASING.md).
#
# Requirements: macOS, openssl, gh (authenticated with repo admin), this repo.
# Cost: $0. The cert is zero-cost to regenerate/rotate (run this again).
#
# Usage:
#   scripts/setup-signing-cert.sh                 # generate + set GitHub secrets
#   scripts/setup-signing-cert.sh --print-only    # generate + print base64, DON'T touch GitHub
set -euo pipefail

CN="Capture Studio Dev"               # cert Common Name == APPLE_SIGNING_IDENTITY == build-app.sh IDENTITY
DAYS=3650                             # 10y; binaries keep working past expiry, just can't sign new ones
PRINT_ONLY=0
[ "${1:-}" = "--print-only" ] && PRINT_ONLY=1

command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }
if [ "$PRINT_ONLY" -eq 0 ]; then
  command -v gh >/dev/null || { echo "error: gh not found (use --print-only to skip)" >&2; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT          # private key + p12 never persist on disk

P12_PASS="$(openssl rand -base64 24)"

# Self-signed cert with the codeSigning EKU — the minimum macOS codesign accepts.
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=${CN}" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CN" -out "$WORK/capture-studio-signing.p12" \
  -passout "pass:${P12_PASS}"

CERT_B64="$(base64 < "$WORK/capture-studio-signing.p12")"

if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "Identity (APPLE_SIGNING_IDENTITY): $CN"
  echo "Password (APPLE_CERTIFICATE_PASSWORD): $P12_PASS"
  echo "Certificate (APPLE_CERTIFICATE) base64 below:"
  echo "$CERT_B64"
  exit 0
fi

printf '%s' "$CERT_B64"   | gh secret set APPLE_CERTIFICATE
printf '%s' "$P12_PASS"   | gh secret set APPLE_CERTIFICATE_PASSWORD
printf '%s' "$CN"         | gh secret set APPLE_SIGNING_IDENTITY

echo "Done. Set 3 GitHub Actions secrets on $(gh repo view --json nameWithOwner -q .nameWithOwner):"
echo "  APPLE_CERTIFICATE           (base64 self-signed p12)"
echo "  APPLE_CERTIFICATE_PASSWORD  (random)"
echo "  APPLE_SIGNING_IDENTITY      = $CN"
echo
echo "Next: cut a release (scripts/release.sh patch && git push --follow-tags)."
echo "Verify a built .app with:  codesign -dv --verbose=4 dist/CaptureStudio.app  (Authority=$CN)"
