#!/bin/bash
# Builds build/Island.app and build/Island.zip.
#   VERSION=0.2.0 stamps the version (CI passes the tag); UNIVERSAL=1 builds for Apple silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Island.app

if [[ -n "${UNIVERSAL:-}" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Island
else
  swift build -c release
  BIN=.build/release/Island
fi

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Island"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp -R Resources/GrokAvatars "$APP/Contents/Resources/"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# SIGN_IDENTITY=<keychain code-signing identity> signs with a certificate, so
# Full Disk Access survives rebuilds too (ad-hoc builds lose it).
# Otherwise ad-hoc, matched by bundle id rather than build hash, so macOS keeps
# the calendar and Spotify permissions across rebuilds and updates.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - -r='designated => identifier "dev.notchisland.Island"' "$APP"
fi
(cd build && rm -f Island.zip && ditto -c -k --keepParent Island.app Island.zip)
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
