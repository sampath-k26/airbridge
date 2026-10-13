#!/bin/bash
# Samples the AirBridge app's total PSS (KB) every 3 s until killed; prints the maximum.
A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
max=0
trap 'echo "phone app max PSS: $((max/1024)) MB"; exit 0' TERM INT
while true; do
  v=$($A shell dumpsys meminfo com.mahi.airbridge 2>/dev/null | awk '/TOTAL PSS:/{print $3; exit} /^ *TOTAL /{print $2; exit}')
  [ -n "$v" ] && [ "$v" -gt "$max" ] 2>/dev/null && max=$v
  sleep 3
done
