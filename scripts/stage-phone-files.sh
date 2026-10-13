#!/bin/bash
# Copies a local directory into the debug app's private files dir (<filesDir>/<name>)
# for automated send tests. Usage: stage-phone-files.sh SRC_DIR [name]
set -euo pipefail
A=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
SRC=${1:?usage: stage-phone-files.sh SRC_DIR [name]}; NAME=${2:-test}
$A shell rm -rf /data/local/tmp/ab-stage && $A shell mkdir -p /data/local/tmp/ab-stage
$A push -q "$SRC/." /data/local/tmp/ab-stage/
$A shell "run-as com.mahi.airbridge rm -rf files/$NAME && run-as com.mahi.airbridge mkdir -p files/$NAME && run-as com.mahi.airbridge cp -r /data/local/tmp/ab-stage/. files/$NAME/"
$A shell rm -rf /data/local/tmp/ab-stage
$A shell "run-as com.mahi.airbridge find files/$NAME -type f" | wc -l | xargs echo "staged files:"
