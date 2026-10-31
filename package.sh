#!/bin/zsh
# Builds a shareable dist/PhoneTrackpad-<version>.zip: universal Mac app, Android APK and README.
# Doesn't touch mac/build/PhoneTrackpad.app (the copy you run here).
set -e
cd "$(dirname "$0")"
VERSION=1.0
OUT=dist/PhoneTrackpad-$VERSION

APP=$PWD/$OUT/PhoneTrackpad.app mac/build.sh
(cd android && ./gradlew assembleDebug -q)
cp android/app/build/outputs/apk/debug/app-debug.apk "$OUT/PhoneTrackpad.apk"
cp README.md "$OUT/README.md"

rm -f "$OUT.zip"
ditto -c -k --keepParent "$OUT" "$OUT.zip"   # ditto keeps the app bundle and its signature intact
echo "Packaged $PWD/$OUT.zip"
