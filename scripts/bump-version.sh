#!/bin/bash
# Bump the marketing version (CFBundleShortVersionString) in Resources/Info.plist.
#
# Usage:
#   scripts/bump-version.sh              # print current version
#   scripts/bump-version.sh patch        # 0.1.0 -> 0.1.1
#   scripts/bump-version.sh minor        # 0.1.0 -> 0.2.0
#   scripts/bump-version.sh major        # 0.1.0 -> 1.0.0
#   scripts/bump-version.sh 1.2.3        # set explicitly
#
# The build number (CFBundleVersion) is NOT touched here: build-app.sh derives
# it from the git commit count at package time, so it always increases.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
PB="/usr/libexec/PlistBuddy"

current="$("$PB" -c "Print :CFBundleShortVersionString" "$PLIST")"

arg="${1:-}"
if [[ -z "$arg" ]]; then
    echo "current version: $current"
    echo "usage: $0 <major|minor|patch|X.Y.Z>"
    exit 0
fi

IFS='.' read -r major minor patch <<<"$current"

case "$arg" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *)
        if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IFS='.' read -r major minor patch <<<"$arg"
        else
            echo "error: bad arg '$arg' (use major|minor|patch|X.Y.Z)" >&2
            exit 1
        fi
        ;;
esac

new="$major.$minor.$patch"
"$PB" -c "Set :CFBundleShortVersionString $new" "$PLIST"

echo "version: $current -> $new"
echo "next: commit, then  git tag v$new"
