#!/bin/bash
# Packages macos/dist/AirBridge.app into a drag-to-Applications disk image.
# Usage: scripts/make-dmg.sh [VERSION]   → dist/AirBridge-<VERSION>.dmg
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-1.1.0}
APP=$ROOT/macos/dist/AirBridge.app
[ -d "$APP" ] || { echo "Build the app first: scripts/build-macos-app.sh"; exit 1; }
OUT=$ROOT/dist/AirBridge-$VERSION.dmg
STAGE=$(mktemp -d -t airbridge-dmg)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
AirBridge for macOS

1. Drag AirBridge onto the Applications folder.
2. This build is not notarized by Apple. The first time, open it with a right-click on
   AirBridge in Applications → Open → Open. If macOS still refuses, go to
   System Settings → Privacy & Security and click "Open Anyway".
3. When asked, allow Local Network access and Keychain access ("Always Allow").

Source, documentation and licence: see the GitHub repository.
TXT
mkdir -p "$ROOT/dist"; rm -f "$OUT"
hdiutil create -volname "AirBridge $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT" >/dev/null
echo "$OUT"
