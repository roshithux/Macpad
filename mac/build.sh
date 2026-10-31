#!/bin/zsh
# Builds PhoneTrackpad.app (universal: Apple Silicon + Intel, ad-hoc signed).
# APP=<path> builds somewhere else, e.g. for packaging, without replacing the running copy.
set -e
cd "$(dirname "$0")"
APP=${APP:-build/PhoneTrackpad.app}
TMP=$(mktemp -d)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp awdl-guard.sh com.phonetrackpad.awdlguard.plist "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos14 PhoneTrackpad.swift -o "$TMP/PhoneTrackpad-$arch"
done
lipo -create "$TMP/PhoneTrackpad-arm64" "$TMP/PhoneTrackpad-x86_64" -output "$APP/Contents/MacOS/PhoneTrackpad"
rm -rf "$TMP"
codesign --force --sign - --identifier com.phonetrackpad.mac "$APP"
echo "Built ${APP:A}"
