#!/bin/zsh
# Builds MenuMeter.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP=MenuMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macos14.2" main.swift -o "$APP/Contents/MacOS/MenuMeter"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
