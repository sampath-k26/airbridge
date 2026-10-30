# AirBridge

**AirDrop ↔ Quick Share native bridge for Mac and Android.**  
Your Android phone shows up directly in Finder's **AirDrop**, and your Mac shows up directly in Android's **Quick Share**.

* **Nothing to install on the phone** — uses Android's built-in Quick Share (Google Play Services / Samsung One UI).
* **Native AirDrop in Finder** — drag and drop files onto the phone directly in the Finder AirDrop window.
* **Zero background battery drain** — sleeps with 0% CPU when AirDrop is turned off, and automatically awakens when AirDrop is active.
* **Tri-Tier Hybrid Connectivity** — works over the same Wi-Fi network, over the phone's mobile hotspot, and across different networks via BLE desk proximity.
* **100+ MB/s High-Throughput Streaming** — 4 MB socket buffers, `TCP_NODELAY`, and 1 MB streaming blocks.

---

## ⚡ Install on macOS

### Option 1: One-Line Terminal Install (No repo cloning needed)

Run this single command in the macOS Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/sunkaramahesh09/airbridge/main/install.sh | bash
```

This automatically downloads the prebuilt binary, installs it to your system PATH, and registers the on-demand AirBridge service.

### Option 2: Homebrew

```bash
brew tap sunkaramahesh09/airbridge https://github.com/sunkaramahesh09/airbridge
brew install airbridge
brew services start airbridge
```

### Option 3: Build from Source

```bash
git clone https://github.com/sunkaramahesh09/airbridge.git
cd airbridge
scripts/build.sh
```

---

## 🗑️ Uninstall / Revert

To completely remove AirBridge and restore your Mac to its default state:

### One-Line Terminal Uninstall
```bash
curl -fsSL https://raw.githubusercontent.com/sunkaramahesh09/airbridge/main/uninstall.sh | bash
```

### Homebrew Uninstall
```bash
brew services stop airbridge
brew uninstall airbridge
rm -rf ~/Library/Application\ Support/airbridge ~/Library/Caches/airbridge
```

### Manual Revert
```bash
launchctl unload ~/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist
rm -f /usr/local/bin/airbridge ~/.local/bin/airbridge
rm -rf ~/Library/Application\ Support/airbridge ~/Library/Caches/airbridge
```

---

## 📱 Quick Setup (Once)

1. **On your Android Phone**:
   - Open **Settings** → **Google** → **Quick Share** (or search "Quick Share" in settings).
   - Set *Who can share with you* to **Everyone** (or your preferred contact setting).
2. **On your Mac**:
   - Ensure **Wi-Fi** and **Bluetooth** are turned on.
   - If prompted for **Local Network** access, click **Allow**.

---

## 🚀 How to Use

| Direction | How to Transfer |
|---|---|
| **Mac → Android** | Open **Finder** → Click **AirDrop** in the sidebar → Drag and drop files onto your Android phone → Tap **Accept** on the phone. |
| **Android → Mac** | Select photos or files on Android → Tap **Share** → Tap **Quick Share** → Pick your Mac → Click **Accept** on the Mac prompt. Files save directly to `~/Downloads`. |

---

## 🌐 Tri-Tier Connection Modes

AirBridge features a three-tier connection engine to ensure transfers always work regardless of network conditions:

1. **Mode 1: Same Wi-Fi Network**
   - Automatically browses local multicast DNS (`_FC9F5ED42C8A._tcp.local.`).
   - Fastest transfer speeds, lowest latency, and zero interruption to your Mac's internet connection.
2. **Mode 2: Mobile Hotspot (Tethering / SoftAP)**
   - When your Mac connects to your phone's mobile hotspot, AirBridge detects the gateway IP (`192.168.43.1`, `172.x.x.x`) and executes a direct unicast DNS-SD probe to `gateway:5353`.
   - Bypasses Android's tethering multicast filters so the hotspot-connected phone is instantly recognized in Finder AirDrop.
3. **Mode 3: BLE Desk Proximity (Different Networks / 5G)**
   - When devices are on different networks, guest Wi-Fi, or cellular data, AirBridge uses Bluetooth Low Energy (Service UUID `0xFEF3`) to detect the phone within desk range (`RSSI >= -70 dBm`).
   - Initiates an automated direct peer-to-peer Wi-Fi / WebRTC channel.

---

## ⚡ 100+ MB/s Speed Optimization

AirBridge is optimized at the kernel and socket layer (4 MB buffers, `TCP_NODELAY`, 1 MB streaming blocks). To hit peak multi-gigabit speeds:

* **Use 5 GHz Wi-Fi**: Connect both devices to a 5 GHz or 6 GHz Wi-Fi SSID with **80 MHz or 160 MHz** channel width.
* **For Mobile Hotspots**: In your phone's Hotspot settings, switch **Speed & Compatibility / AP Band** from 2.4 GHz to **5 GHz**. (2.4 GHz defaults to ~6 MB/s, while 5 GHz unlocks 40–100+ MB/s).
* **Android Power Save**: Ensure *Wi-Fi Power Saving Mode* is disabled in Samsung/Pixel Wi-Fi settings during large transfers.

For deep performance details, see [`docs/performance.md`](docs/performance.md).

---

## 🩺 Diagnostics & CLI Commands

Check your network, AirDrop status, and reachable devices:

```bash
airbridge doctor
```

Example output:
```text
=== AirBridge Diagnostics ===
macOS AirDrop Status  : Everyone
AWDL Interface (awdl0): ACTIVE (OK)
Mode 1 (Wi-Fi LAN)    : Enabled (mDNS _FC9F5ED42C8A._tcp.local)
Mode 2 (Hotspot AP)   : Gateway 192.168.43.1 on en0 [Mobile Hotspot DETECTED]
Mode 3 (Desk Proximity: BLE Scanner Active (UUID 0xFEF3, threshold: -70 dBm)
Known Devices         : saved in names.tsv
=============================
```

### CLI Commands & Service Control:
* `airbridge status`: View current background service status, process PID, macOS AirDrop mode, and Finder status.
* `airbridge stop`: Completely stop the background service and any active AirBridge processes.
* `airbridge start`: Start/resume the background service.
* `airbridge doctor`: Run diagnostics on network interfaces, AirDrop link, and hotspot routing.
* `airbridge --auto-accept`: Accept incoming Quick Share files without confirmation dialog.
* `airbridge --download-dir <path>`: Customize destination folder (default: `~/Downloads`).
* `airbridge qr [<file>...]`: Generate a terminal QR code for phones that hide their name.
* `airbridge --always-on`: Run continuously instead of stopping when AirDrop is turned off.

---

## 🔒 Security

* **Source Isolation**: Mock AirDrop listeners on AWDL strictly reject connections from neighboring Macs; only this Mac's Finder can connect.
* **Path Sanitization**: All archive filenames are sanitized to prevent directory traversal (`safe_relative` enforces `Component::Normal`).
* **POSIX Key Protection**: TLS private keys are stored with restricted permissions (`0600`).
* **Explicit Consent**: Inbound transfers prompt the user with device name and PIN before writing to disk.

See [`docs/security.md`](docs/security.md) for full details.

---

## License

GPL-3.0 License. See [LICENSE](LICENSE).
