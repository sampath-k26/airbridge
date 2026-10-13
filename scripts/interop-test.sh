#!/bin/bash
# Cross-implementation test: Swift (macOS) ⇄ Kotlin (JVM build of android/core) on loopback.
# Each scenario pairs fresh identities, then BOTH sides send the corpus over one session.
# Usage: interop-test.sh [CORPUS_DIR]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT=$ROOT/macos/.build/debug/airbridge-cli
JVM=$ROOT/android/core/build/install/airbridge-jvm/bin/airbridge-jvm
WORK=$(mktemp -d -t airbridge-interop)
CORPUS=${1:-$WORK/corpus}
[ -d "$CORPUS" ] || "$ROOT/scripts/generate-test-files.sh" "$CORPUS" >/dev/null
PASS=0; FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }

uri_of() { for _ in $(seq 1 100); do u=$(grep -o '"uri":"[^"]*"' "$1" 2>/dev/null | head -1 | cut -d'"' -f4); [ -n "$u" ] && { echo "$u" | sed -E 's/h=[^&]*/h=127.0.0.1/'; return; }; sleep 0.1; done; }
port_of() { echo "$1" | sed -E 's/.*[?&]p=([0-9]+).*/\1/'; }

scenario() { # name listenerBin dialerBin pairingMode(qr|code)
  local name=$1 L=$2 D=$3 mode=$4 S=$WORK/$1
  mkdir -p "$S/recvL" "$S/recvD"
  echo "=== $name ($mode pairing)"
  "$L" listen --state "$S/stL" --dir "$S/recvL" --port 0 --code K7M2P-Q9RST --expect 1 --send "$CORPUS"/* --name listener >"$S/l.log" 2>&1 &
  local lp=$!
  local uri; uri=$(uri_of "$S/l.log")
  if [ "$mode" = qr ]; then
    "$D" dial --state "$S/stD" --dir "$S/recvD" --uri "$uri" --expect 1 --send "$CORPUS"/* --name dialer >"$S/d.log" 2>&1
  else
    "$D" dial --state "$S/stD" --dir "$S/recvD" --host 127.0.0.1 --port "$(port_of "$uri")" --code k7m2p-q9rst --expect 1 --send "$CORPUS"/* --name dialer >"$S/d.log" 2>&1
  fi
  local drc=$?; wait $lp; local lrc=$?
  echo "listener rc=$lrc dialer rc=$drc"; grep -h '"event":"result"\|"event":"error"\|"result"' "$S/l.log" "$S/d.log" | cut -c1-200
  check [ $lrc -eq 0 ] && check [ $drc -eq 0 ]
  echo "-- dialer → listener"; check "$ROOT/scripts/verify-checksums.sh" "$CORPUS" "$S/recvL"
  echo "-- listener → dialer"; check "$ROOT/scripts/verify-checksums.sh" "$CORPUS" "$S/recvD"
}

scenario swiftL-jvmD-qr   "$SWIFT" "$JVM"   qr
scenario jvmL-swiftD-qr   "$JVM"   "$SWIFT" qr
scenario swiftL-jvmD-code "$SWIFT" "$JVM"   code
scenario jvmL-swiftD-code "$JVM"   "$SWIFT" code
scenario jvmL-jvmD-qr     "$JVM"   "$JVM"   qr
scenario swiftL-swiftD-qr "$SWIFT" "$SWIFT" qr

echo; echo "INTEROP: $PASS checks passed, $FAIL failed (work dir $WORK)"
[ $FAIL -eq 0 ]
