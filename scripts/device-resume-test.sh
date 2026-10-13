#!/bin/bash
# Real-device interruption/resume test (run inside hotspot-session.sh).
# 1. Mac starts sending a large file to the phone.  2. The Mac process is killed
# mid-transfer (connection reset).  3. A new Mac process (same identity) starts.
# 4. The phone reconnects by itself; the transfer resumes from the stored offset.
# Usage: device-resume-test.sh WORKDIR FILE
set -u
A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/macos/.build/release/airbridge-cli
W=${1:?}; FILE=${2:?}; TID="resume-$(date +%s)"
NAME=$(basename "$FILE")
mkdir -p "$W"
svc() { $A shell am start-foreground-service -n com.mahi.airbridge/.debug.DebugControlService "$@" >/dev/null; }
$A shell rm -f "/sdcard/Download/AirBridge/$NAME"
$A logcat -c
"$CLI" listen --state "$W/st" --dir "$W/recv" --port 47820 --code AB12C-DE34F --send "$FILE" --transfer-id "$TID" --name "MacBook Air" > "$W/mac1.log" 2>&1 &
P1=$!
URI=""
for _ in $(seq 1 100); do  # first launch of a new binary can take seconds
  URI=$(grep -o '"uri":"[^"]*"' "$W/mac1.log" 2>/dev/null | cut -d'"' -f4 | sed -E "s/h=[^&]*/h=$MAC_HOTSPOT_IP/")
  [ -n "$URI" ] && break; sleep 0.2
done
svc -a connect --es uri "'$URI'"
sleep 9
kill -9 $P1; echo "killed Mac sender after 9 s"
sleep 4
$A logcat -d -s AirBridgeTest:I | grep -o '"state":"[A-Za-z]*' | tail -3
"$CLI" listen --state "$W/st" --dir "$W/recv" --port 47820 --code AB12C-DE34F --send "$FILE" --transfer-id "$TID" --name "MacBook Air" > "$W/mac2.log" 2>&1 &
P2=$!
for i in $(seq 1 120); do grep -q '"direction":"send"' "$W/mac2.log" && break; sleep 1; done
sleep 2
kill $P2 2>/dev/null
svc -a disconnect
echo "second run:"; grep -E '"connected"|"result"' "$W/mac2.log" | cut -c1-220
$A logcat -d -s AirBridgeTest:I | grep -v '"connection"' | cut -c40-260
echo "phone file sha256: $($A shell sha256sum "/sdcard/Download/AirBridge/$NAME" | cut -c1-64)"
echo "source sha256:     $(shasum -a 256 "$FILE" | cut -c1-64)"
$A shell ls /sdcard/Download/AirBridge/ | grep -c "$NAME" | xargs echo "copies on phone:"
