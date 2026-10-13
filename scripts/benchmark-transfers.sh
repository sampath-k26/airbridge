#!/bin/bash
# Repeatable throughput benchmarks. Results are appended as JSON lines to
# benchmarks/results.jsonl and summarised on stdout.
#
#   benchmark-transfers.sh loopback [SIZE_MB] [RUNS]   Swift⇄Swift and JVM→Swift on this Mac (engine ceiling)
#   benchmark-transfers.sh device   [SIZE_MB] [RUNS]   Mac⇄phone over the current Wi-Fi/hotspot (needs MAC_HOTSPOT_IP;
#                                                     run inside scripts/hotspot-session.sh)
# Chunk sizes: CHUNKS="65536 262144 1048576 4194304" (override via env).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:?loopback|device}; SIZE_MB=${2:-1024}; RUNS=${3:-1}
CHUNKS=${CHUNKS:-"65536 262144 1048576 4194304"}
SWIFT=$ROOT/macos/.build/release/airbridge-cli
JVM=$ROOT/android/core/build/install/airbridge-jvm/bin/airbridge-jvm
OUT=$ROOT/benchmarks/results.jsonl
W=$(mktemp -d -t airbridge-bench)
mkdir -p "$W/src"
head -c $((SIZE_MB * 1048576)) /dev/urandom > "$W/src/payload.bin"
HOSTINFO="$(sysctl -n hw.model) macOS $(sw_vers -productVersion)"
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Parses `/usr/bin/time -l` output → "cpu_seconds max_rss_MB"
timestats() { awk '/ real /{cpu=$3+$5} /maximum resident set size/{rss=$1/1048576} END{printf "%.2f %.1f", cpu, rss}' "$1"; }
# Extracts a numeric field from a JSON line; prints "null" when absent (failed run).
field() { local v; v=$(grep -o "\"$2\":[^,}]*" "$1" 2>/dev/null | head -1 | cut -d: -f2 | tr -d '"'); echo "${v:-null}"; }

record() { echo "$1" >> "$OUT"; echo "$1"; }

loopback_run() { # sender receiver chunk run
  local S=$1 R=$2 chunk=$3 run=$4 d="$W/$1-$2-$3-$4"
  mkdir -p "$d/recv"
  /usr/bin/time -l "$( [ "$R" = swift ] && echo "$SWIFT" || echo "$JVM")" listen --state "$d/stR" --dir "$d/recv" --port 0 \
      --code AB12C-DE34F --expect 1 --chunk "$chunk" > "$d/r.log" 2> "$d/r.time" &
  local rp=$!
  local uri=""; for _ in $(seq 1 100); do uri=$(grep -o '"uri":"[^"]*"' "$d/r.log" 2>/dev/null | cut -d'"' -f4); [ -n "$uri" ] && break; sleep 0.1; done
  uri=$(echo "$uri" | sed -E 's/h=[^&]*/h=127.0.0.1/')
  /usr/bin/time -l "$( [ "$S" = swift ] && echo "$SWIFT" || echo "$JVM")" dial --state "$d/stS" --dir "$d" --uri "$uri" \
      --chunk "$chunk" --send "$W/src/payload.bin" > "$d/s.log" 2> "$d/s.time"
  wait $rp
  read scpu srss < <(timestats "$d/s.time"); read rcpu rrss < <(timestats "$d/r.time")
  local ok=$(cmp -s "$W/src/payload.bin" "$d/recv/payload.bin" && echo true || echo false)
  record "{\"date\":\"$STAMP\",\"kind\":\"loopback\",\"host\":\"$HOSTINFO\",\"sender\":\"$S\",\"receiver\":\"$R\",\"chunk\":$chunk,\"run\":$run,\"bytes\":$((SIZE_MB*1048576)),\"seconds\":$(field "$d/s.log" seconds),\"MBps\":$(field "$d/s.log" MBps),\"senderCpuS\":$scpu,\"receiverCpuS\":$rcpu,\"senderMaxRssMB\":$srss,\"receiverMaxRssMB\":$rrss,\"verified\":$ok}"
  rm -rf "$d/recv"
}

device_run() { # chunk run
  local chunk=$1 run=$2 d="$W/dev-$1-$2"
  mkdir -p "$d/mac"
  cp "$W/src/payload.bin" "$d/mac/mac-payload.bin"
  "$ROOT/scripts/device-wireless-test.sh" "$d" "$d/mac" bench "$chunk" > "$d/out.log" 2>&1
  local m2p=$(grep '"direction":"send"' "$d/mac.log" | head -1)
  local p2m=$(grep '"direction":"receive"' "$d/mac.log" | head -1)
  local okp2m=$(cmp -s "$W/phone-payload.bin" "$d/recv/phone-payload.bin" && echo true || echo false)
  local phoneSha=$(${ADB:-$HOME/Library/Android/sdk/platform-tools/adb} shell sha256sum /sdcard/Download/AirBridge/mac-payload.bin 2>/dev/null | cut -c1-64)
  local okm2p=$([ "$phoneSha" = "$(shasum -a 256 "$W/src/payload.bin" | cut -c1-64)" ] && echo true || echo false)
  ${ADB:-$HOME/Library/Android/sdk/platform-tools/adb} shell rm -f /sdcard/Download/AirBridge/mac-payload.bin
  echo "$m2p" > "$d/m2p"; echo "$p2m" > "$d/p2m"
  record "{\"date\":\"$STAMP\",\"kind\":\"device\",\"link\":\"${LINK:-unknown}\",\"direction\":\"mac->phone\",\"chunk\":$chunk,\"run\":$run,\"bytes\":$((SIZE_MB*1048576)),\"seconds\":$(field "$d/m2p" seconds),\"MBps\":$(field "$d/m2p" MBps),\"verified\":$okm2p}"
  record "{\"date\":\"$STAMP\",\"kind\":\"device\",\"link\":\"${LINK:-unknown}\",\"direction\":\"phone->mac\",\"chunk\":$chunk,\"run\":$run,\"bytes\":$((SIZE_MB*1048576)),\"seconds\":$(field "$d/p2m" seconds),\"MBps\":$(field "$d/p2m" MBps),\"verified\":$okp2m}"
  rm -rf "$d/recv" "$d/mac"
}

case "$MODE" in
  loopback)
    for chunk in $CHUNKS; do for run in $(seq 1 "$RUNS"); do
      loopback_run swift swift "$chunk" "$run"
      loopback_run jvm swift "$chunk" "$run"
    done; done ;;
  device)
    : "${MAC_HOTSPOT_IP:?run inside scripts/hotspot-session.sh}"
    ${ADB:-$HOME/Library/Android/sdk/platform-tools/adb} shell pm list packages | grep -q com.mahi.airbridge \
      || { echo "AirBridge debug app is not installed on the phone"; exit 1; }
    # Phone-side payload is generated on the phone (private app dir) and copied back for comparison.
    A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    $A shell "run-as com.mahi.airbridge sh -c 'rm -rf files/bench; mkdir -p files/bench; dd if=/dev/urandom of=files/bench/phone-payload.bin bs=1048576 count=$SIZE_MB 2>/dev/null'"
    $A shell "run-as com.mahi.airbridge cat files/bench/phone-payload.bin" > "$W/phone-payload.bin"
    for chunk in $CHUNKS; do for run in $(seq 1 "$RUNS"); do device_run "$chunk" "$run"; done; done ;;
esac
rm -rf "$W"
