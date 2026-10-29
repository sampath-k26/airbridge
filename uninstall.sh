#!/usr/bin/env bash
# AirBridge Mac Uninstaller / Revert Script
# One-line uninstall: curl -fsSL https://raw.githubusercontent.com/sunkaramahesh09/airbridge/main/uninstall.sh | bash

set -e

# Color formatting
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}====================================================${RESET}"
echo -e "${BOLD}${RED}             AirBridge Uninstaller                  ${RESET}"
echo -e "${BOLD}${BLUE}====================================================${RESET}"
echo ""

# 1. Stop and remove background LaunchAgent
PLIST_FILE="$HOME/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist"
if [ -f "$PLIST_FILE" ]; then
    echo "Stopping and removing background LaunchAgent service..."
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
    echo -e "${GREEN}✔ LaunchAgent service removed.${RESET}"
fi

# 2. Terminate any running airbridge process
echo "Stopping any running AirBridge processes..."
killall airbridge 2>/dev/null || true

# 3. Remove installed binaries
REMOVED_BIN=false
for BIN_PATH in "/usr/local/bin/airbridge" "/opt/homebrew/bin/airbridge" "$HOME/.local/bin/airbridge"; do
    if [ -f "$BIN_PATH" ]; then
        echo "Removing binary at $BIN_PATH..."
        if [ -w "$(dirname "$BIN_PATH")" ]; then
            rm -f "$BIN_PATH"
        else
            sudo rm -f "$BIN_PATH"
        fi
        REMOVED_BIN=true
    fi
done

if [ "$REMOVED_BIN" = true ]; then
    echo -e "${GREEN}✔ AirBridge binary removed.${RESET}"
else
    echo "No installed AirBridge binary found in standard PATHs."
fi

# 4. Clean up caches, certificates, and application data
DATA_DIR="$HOME/Library/Application Support/airbridge"
CACHE_DIR="$HOME/Library/Caches/airbridge"
LOG_OUT="/tmp/airbridge.log"
LOG_ERR="/tmp/airbridge.err"

if [ -d "$DATA_DIR" ] || [ -d "$CACHE_DIR" ]; then
    echo "Removing Application Support certificates and device cache..."
    rm -rf "$DATA_DIR" "$CACHE_DIR"
fi

rm -f "$LOG_OUT" "$LOG_ERR"

echo ""
echo -e "${BOLD}${GREEN}✔ AirBridge has been completely uninstalled and reverted!${RESET}"
echo "Your Mac is fully restored to its default state."
echo ""
