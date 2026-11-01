#!/bin/bash
# Builds Foglietti and creates Foglietti.app in build/.  Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Foglietti.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Foglietti "$APP/Contents/MacOS/Foglietti"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift Scripts/make_icon.swift build/icon_1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# local (ad-hoc) signature: enough to run it on your own Mac
codesign --force --sign - "$APP"
echo "Created $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x Foglietti 2>/dev/null || true
    rm -rf /Applications/Foglietti.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Foglietti.app"
fi
