# Installation Guide

AirBridge is a zero-app bridge: **no app is needed on your Android phone**. You only install the lightweight AirBridge utility on your Mac.

---

## Method 1: One-Line Terminal Install (Recommended)

Run this single command in your macOS Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/sunkaramahesh09/airbridge/main/install.sh | bash
```

### What this does:
1. Detects your Mac hardware (Apple Silicon `arm64` or Intel `x86_64`).
2. Downloads the prebuilt binary and places it in your system PATH (`/usr/local/bin` or `~/.local/bin`).
3. Clears macOS Gatekeeper quarantine flags automatically.
4. Sets up a background LaunchAgent (`~/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist`) so AirBridge starts automatically on login and operates on-demand with AirDrop.

---

## Method 2: Homebrew

If you use Homebrew:

```bash
# Tap and install
brew install sunkaramahesh09/tap/airbridge

# Start as a background service
brew services start airbridge
```

---

## Method 3: Build from Source

If you have Rust installed:

```bash
git clone https://github.com/sunkaramahesh09/airbridge.git
cd airbridge
cargo build --release
sudo cp target/release/airbridge /usr/local/bin/
```

---

## Verifying the Installation

Run the built-in diagnostic tool:

```bash
airbridge doctor
```

If macOS displays a prompt asking for **Local Network** access, click **Allow**.
