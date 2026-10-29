#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Proofmark.app and zips it for a GitHub release.
set -e
cd "$(dirname "$0")"
(cd macos && swift build -c release --arch arm64 --arch x86_64 -q)
BIN="$(cd macos && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Proofmark"
APP=build/Proofmark.app
rm -rf "$APP" build/Proofmark.zip && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/" && cp macos/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent Proofmark.app Proofmark.zip)
echo "build/Proofmark.zip ready"
