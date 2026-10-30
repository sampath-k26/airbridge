#!/usr/bin/env bash
# AirBridge Mac Terminal Installer
# One-line install: curl -fsSL https://raw.githubusercontent.com/sunkaramahesh09/airbridge/main/install.sh | bash

set -e

REPO="sunkaramahesh09/airbridge"
BINARY_NAME="airbridge"

# Color formatting
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}====================================================${RESET}"
echo -e "${BOLD}${GREEN}   AirBridge: Native AirDrop ↔ Quick Share Bridge   ${RESET}"
echo -e "${BOLD}${BLUE}====================================================${RESET}"
echo ""

# 1. Verify macOS
OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo -e "${RED}Error: AirBridge is specifically designed for macOS (Apple Silicon / Intel).${RESET}"
    echo "Current operating system is $OS."
    exit 1
fi

# 2. Detect Architecture
ARCH="$(uname -m)"
echo -e "Detected architecture: ${BOLD}${ARCH}${RESET} (macOS $(sw_vers -productVersion))"

# 3. Determine Installation Directory
INSTALL_DIR=""
if [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
elif [ -d "/opt/homebrew/bin" ] && [ -w "/opt/homebrew/bin" ]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    # Ensure in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        ZSHRC="$HOME/.zshrc"
        if [ -f "$ZSHRC" ]; then
            if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$ZSHRC"; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
                echo -e "${YELLOW}Added ~/.local/bin to $ZSHRC.${RESET}"
            fi
        fi
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

TARGET_BIN="$INSTALL_DIR/$BINARY_NAME"
echo -e "Installing binary to: ${BOLD}$TARGET_BIN${RESET}"

# 4. Download prebuilt release or build from source
TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

RELEASE_URL="https://github.com/$REPO/releases/latest/download/airbridge-macos-${ARCH}.tar.gz"
FALLBACK_URL="https://github.com/$REPO/releases/latest/download/airbridge-macos.tar.gz"

echo -e "Downloading AirBridge release from GitHub..."
DOWNLOAD_SUCCESS=false

if curl -sSfL "$RELEASE_URL" -o "$TEMP_DIR/airbridge.tar.gz" 2>/dev/null; then
    tar -xzf "$TEMP_DIR/airbridge.tar.gz" -C "$TEMP_DIR"
    DOWNLOAD_SUCCESS=true
elif curl -sSfL "$FALLBACK_URL" -o "$TEMP_DIR/airbridge.tar.gz" 2>/dev/null; then
    tar -xzf "$TEMP_DIR/airbridge.tar.gz" -C "$TEMP_DIR"
    DOWNLOAD_SUCCESS=true
fi

if [ "$DOWNLOAD_SUCCESS" = true ] && [ -f "$TEMP_DIR/$BINARY_NAME" ]; then
    mv "$TEMP_DIR/$BINARY_NAME" "$TARGET_BIN"
    chmod +x "$TARGET_BIN"
else
    echo -e "${YELLOW}Prebuilt release asset not found. Building from source...${RESET}"
    
    # 1. Ensure Rust / Cargo is installed
    if ! command -v cargo >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            echo -e "${BLUE}Cargo not found. Installing Rust via Homebrew...${RESET}"
            brew install rust
        else
            echo -e "${BLUE}Cargo not found. Installing Rust via rustup...${RESET}"
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            if [ -f "$HOME/.cargo/env" ]; then
                source "$HOME/.cargo/env"
            fi
        fi
    fi

    # 2. Ensure Protobuf compiler (protoc) is installed for rqs_lib
    if ! command -v protoc >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            echo -e "${BLUE}Installing Protobuf (required for Quick Share protocol) via Homebrew...${RESET}"
            brew install protobuf
        fi
    fi

    if command -v brew >/dev/null 2>&1 && [ -f "$(brew --prefix protobuf 2>/dev/null)/bin/protoc" ]; then
        export PROTOC="$(brew --prefix protobuf)/bin/protoc"
    elif command -v protoc >/dev/null 2>&1; then
        export PROTOC="$(which protoc)"
    fi

    if command -v cargo >/dev/null 2>&1; then
        echo -e "${BLUE}Compiling AirBridge with Cargo...${RESET}"
        cargo install --git "https://github.com/$REPO.git" --bin "$BINARY_NAME" --root "$TEMP_DIR"
        mv "$TEMP_DIR/bin/$BINARY_NAME" "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
    else
        echo -e "${RED}Error: Unable to install Rust/Cargo automatically.${RESET}"
        echo "Please install Rust (https://rustup.rs) or install via Homebrew:"
        echo "  brew tap $REPO https://github.com/$REPO"
        echo "  brew install airbridge"
        exit 1
    fi
fi

# Remove Gatekeeper quarantine flag
xattr -dr com.apple.quarantine "$TARGET_BIN" 2>/dev/null || true

# 5. Optional LaunchAgent setup for on-demand background service
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/com.sunkaramahesh.airbridge.plist"

mkdir -p "$PLIST_DIR"
cat <<EOF > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sunkaramahesh.airbridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LaunchEvents</key>
    <dict>
        <key>com.apple.notifyd.matching</key>
        <dict>
            <key>com.apple.sharingd.DiscoverableModeChanged</key>
            <dict>
                <key>Notification</key>
                <string>com.apple.sharingd.DiscoverableModeChanged</string>
            </dict>
            <key>com.apple.sharingd.FinderAirDropChanged</key>
            <dict>
                <key>Notification</key>
                <string>com.apple.sharingd.FinderAirDropChanged</string>
            </dict>
        </dict>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/airbridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/airbridge.err</string>
</dict>
</plist>
EOF

# Load the service
launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE" 2>/dev/null || true

echo ""
echo -e "${BOLD}${GREEN}✔ AirBridge successfully installed and activated!${RESET}"
echo ""
echo -e "Usage:"
echo -e "  • ${BOLD}Finder AirDrop${RESET} : Your Android phone now appears directly in AirDrop!"
echo -e "  • ${BOLD}Quick Share${RESET}    : Share any file from Android to this Mac with Quick Share."
echo -e "  • ${BOLD}Status${RESET}         : Run '${GREEN}airbridge status${RESET}' to view current state."
echo -e "  • ${BOLD}Stop Service${RESET}   : Run '${GREEN}airbridge stop${RESET}' to stop AirBridge."
echo -e "  • ${BOLD}Start Service${RESET}  : Run '${GREEN}airbridge start${RESET}' to resume AirBridge."
echo -e "  • ${BOLD}Diagnostics${RESET}    : Run '${GREEN}airbridge doctor${RESET}' to verify link and interfaces."
echo ""
echo -e "AirBridge operates ${BOLD}on-demand${RESET} with macOS AirDrop. When AirDrop is turned OFF"
echo -e "or Finder AirDrop is closed, AirBridge automatically deactivates and stops running."
echo ""
