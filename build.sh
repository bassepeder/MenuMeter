#!/bin/zsh
# Builds MenuMeter.app next to this script. Pass --release to build a universal
# (Apple silicon + Intel) app and zip it as MenuMeter.zip.
set -euo pipefail
cd "$(dirname "$0")"

APP=MenuMeter.app
BIN="$APP/Contents/MacOS/MenuMeter"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

if [[ "${1:-}" == "--release" ]]; then
    swiftc -O -target arm64-apple-macos14.2 main.swift -o "$BIN.arm64"
    swiftc -O -target x86_64-apple-macos14.2 main.swift -o "$BIN.x86_64"
    lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
    rm "$BIN.arm64" "$BIN.x86_64"
else
    swiftc -O -target "$(uname -m)-apple-macos14.2" main.swift -o "$BIN"
fi

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--release" ]]; then
    rm -f MenuMeter.zip
    ditto -c -k --keepParent "$APP" MenuMeter.zip
    echo "Built $PWD/MenuMeter.zip"
else
    echo "Built $PWD/$APP"
fi
