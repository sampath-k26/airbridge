#!/bin/bash
# Real-device wireless test (run inside hotspot-session.sh, which exports MAC_HOTSPOT_IP).
# 1) Mac → phone: Mac CLI sends $MAC_FILES; 2) phone → Mac: phone sends <filesDir>/$PHONE_DIR.
# Usage: device-wireless-test.sh WORKDIR MAC_FILES_DIR PHONE_DIR [CHUNK_BYTES]
set -u
A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/macos/.build/release/airbridge-cli; [ -x "$CLI" ] || CLI=$ROOT/macos/.build/debug/airbridge-cli
W=${1:?}; MAC_FILES=${2:?}; PHONE_DIR=${3:?}; CHUNK=${4:-1048576}
mkdir -p "$W/recv"; : > "$W/phone.log"
svc() { $A shell am start-foreground-service -n com.mahi.airbridge/.debug.DebugControlService "$@" >/dev/null; }
$A logcat -c
svc -a chunk --ei chunk "$CHUNK"
"$CLI" listen --state "$W/st" --dir "$W/recv" --port 47820 --code AB12C-DE34F --expect 1 --chunk "$CHUNK" \
    --send "$MAC_FILES"/* --name "MacBook Air" > "$W/mac.log" 2>&1 &
CLIPID=$!
URI=""
for _ in $(seq 1 100); do  # first launch of a new binary can take seconds
  URI=$(grep -o '"uri":"[^"]*"' "$W/mac.log" 2>/dev/null | cut -d'"' -f4 | sed -E "s/h=[^&]*/h=$MAC_HOTSPOT_IP/")
  [ -n "$URI" ] && break; sleep 0.2
done
svc -a connect --es uri "'$URI'"
for i in $(seq 1 240); do grep -q '"direction":"send"' "$W/mac.log" && break; sleep 0.5; done
svc -a send --es dir "$PHONE_DIR"
for i in $(seq 1 480); do grep -q '"direction":"receive"' "$W/mac.log" && break; sleep 0.5; done
sleep 1
kill $CLIPID 2>/dev/null
svc -a disconnect
$A logcat -d -s AirBridgeTest:I AndroidRuntime:E > "$W/phone.log"
echo "mac log:"; cut -c1-230 "$W/mac.log"
echo "phone log:"; grep -v '"connection"' "$W/phone.log" | cut -c1-230
