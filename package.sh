#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Proofmark.app and zips it for a GitHub release.
set -e
cd "$(dirname "$0")"
(cd macos && swift build -c release --arch arm64 --arch x86_64 -q)
BIN="$(cd macos && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Proofmark"
APP=build/release/Proofmark.app  # kept apart so the locally granted run.sh build keeps its permissions
rm -rf build/release && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/" && cp macos/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
(cd build/release && ditto -c -k --keepParent Proofmark.app Proofmark.zip)
echo "build/release/Proofmark.zip ready"
