#!/bin/bash
# Runs a command while the Mac is joined to the phone hotspot, then ALWAYS rejoins
# the home network. Used for unattended real-device tests on networks without
# internet. Usage: HOTSPOT_SSID=.. HOTSPOT_PASS=.. hotspot-session.sh <cmd...>
set -u
IF=${WIFI_IF:-en0}
log() { echo "[hotspot $(date +%H:%M:%S)] $*"; }
rejoin() {
  # `networksetup -setairportnetwork` cannot read the saved home password without a
  # keychain prompt (error -3900). Instead forget the hotspot and power-cycle Wi-Fi so
  # macOS auto-joins the home network with its stored credentials.
  for i in 1 2 3 4 5; do
    networksetup -removepreferredwirelessnetwork "$IF" "$HOTSPOT_SSID" >/dev/null 2>&1
    networksetup -setairportpower "$IF" off; sleep 3; networksetup -setairportpower "$IF" on
    for t in $(seq 1 10); do sleep 3; case "$(ipconfig getifaddr "$IF")" in 172.*|"") ;; *) break;; esac; done
    ip=$(ipconfig getifaddr "$IF")
    case "$ip" in 172.*|"") log "rejoin attempt $i: ip=$ip";; *) log "back on home network ($ip)"; return 0;; esac
  done
  log "WARNING: could not rejoin home network"
}
trap rejoin EXIT
joined=""
for i in 1 2 3 4; do
  networksetup -setairportnetwork "$IF" "$HOTSPOT_SSID" "$HOTSPOT_PASS" >/dev/null 2>&1
  sleep 6
  ip=$(ipconfig getifaddr "$IF")
  log "join attempt $i: ip=$ip"
  case "$ip" in 172.*|192.168.43.*|10.*) joined=$ip; break;; esac
done
[ -z "$joined" ] && { log "could not join hotspot"; exit 2; }
export MAC_HOTSPOT_IP=$joined
export PHONE_HOTSPOT_IP=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
log "mac=$MAC_HOTSPOT_IP phone=$PHONE_HOTSPOT_IP"
"$@"
rc=$?
log "command exit $rc (mac ip now $(ipconfig getifaddr "$IF"))"
exit $rc
