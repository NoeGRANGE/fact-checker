#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Margin.app and zips it for a GitHub release.
set -e
cd "$(dirname "$0")"
(cd macos && swift build -c release --arch arm64 --arch x86_64 -q)
BIN="$(cd macos && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Margin"
APP=build/Margin.app
rm -rf "$APP" build/Margin.zip && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/" && cp macos/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent Margin.app Margin.zip)
echo "build/Margin.zip ready"
