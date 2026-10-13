#!/bin/bash
# Phone → Mac interruption test (run inside hotspot-session.sh): the Mac receiver is
# killed mid-transfer and restarted; the phone must reconnect and resume its queued send.
# Usage: device-resume-test-p2m.sh WORKDIR SIZE_MB
set -u
A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/macos/.build/release/airbridge-cli
W=${1:?}; SIZE=${2:-100}
mkdir -p "$W/recv"
svc() { $A shell am start-foreground-service -n com.mahi.airbridge/.debug.DebugControlService "$@" >/dev/null; }
$A shell "run-as com.mahi.airbridge sh -c 'rm -rf files/p2m; mkdir -p files/p2m; dd if=/dev/urandom of=files/p2m/phone-resume.bin bs=1048576 count=$SIZE 2>/dev/null'"
SRC_SHA=$($A shell "run-as com.mahi.airbridge sha256sum files/p2m/phone-resume.bin" | cut -c1-64)
$A logcat -c
"$CLI" listen --state "$W/st" --dir "$W/recv" --port 47820 --code AB12C-DE34F --expect 1 --name "MacBook Air" > "$W/mac1.log" 2>&1 &
P1=$!
URI=""; for _ in $(seq 1 100); do URI=$(grep -o '"uri":"[^"]*"' "$W/mac1.log" 2>/dev/null | cut -d'"' -f4 | sed -E "s/h=[^&]*/h=$MAC_HOTSPOT_IP/"); [ -n "$URI" ] && break; sleep 0.2; done
svc -a connect --es uri "'$URI'"
for _ in $(seq 1 50); do grep -q '"connected"' "$W/mac1.log" && break; sleep 0.2; done
svc -a send --es dir p2m
sleep 9
kill -9 $P1; echo "killed Mac receiver after 9 s; partial: $(ls -l "$W"/recv/.airbridge-partial/*/0.part 2>/dev/null | awk '{print $5}') bytes"
sleep 3
"$CLI" listen --state "$W/st" --dir "$W/recv" --port 47820 --code AB12C-DE34F --expect 1 --name "MacBook Air" > "$W/mac2.log" 2>&1 &
P2=$!
for _ in $(seq 1 150); do grep -q '"direction":"receive"' "$W/mac2.log" && break; sleep 1; done
sleep 1; kill $P2 2>/dev/null; svc -a disconnect
echo "second run:"; grep -E '"connected"|"result"' "$W/mac2.log" | cut -c1-200
$A logcat -d -s AirBridgeTest:I | grep -E '"result"|Reconnecting' | cut -c40-230 | tail -4
echo "mac file sha256:   $(shasum -a 256 "$W/recv/phone-resume.bin" 2>/dev/null | cut -c1-64)"
echo "phone source sha:  $SRC_SHA"
