#!/bin/bash
# Builds macos/dist/AirBridge.app (release, ad-hoc signed — not notarized).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/macos"
swift build -c release --product AirBridge
BIN=$(swift build -c release --show-bin-path)/AirBridge
APP=dist/AirBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirBridge"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION=${VERSION:-1.1.0}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AirBridge</string>
    <key>CFBundleDisplayName</key><string>AirBridge</string>
    <key>CFBundleIdentifier</key><string>com.mahi.airbridge</string>
    <key>CFBundleExecutable</key><string>AirBridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AirBridge connects directly to your phone on the local network to send and receive files. Nothing is uploaded to the internet.</string>
    <key>NSBonjourServices</key>
    <array><string>_airbridge._tcp</string></array>
</dict>
</plist>
PLIST
# Ad-hoc signature with hardened runtime. Not a Developer ID signature: Gatekeeper
# will ask for confirmation on first launch on other Macs (see docs/installation.md).
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $ROOT/macos/$APP"
