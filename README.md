# AirBridge

**Native AirDrop ↔ Quick Share bridge for Mac and Android.**  
Your Android phone shows up directly in Finder's **AirDrop**, and your Mac shows up directly in Android's **Quick Share**.

* **Zero app required on the phone** — uses Android's built-in Quick Share (Google Play Services / Samsung One UI).
* **Native AirDrop in Finder** — drag and drop directly onto the phone in Finder AirDrop.
* **Zero background battery drain** — sleeps with 0% CPU when AirDrop is turned off, and automatically awakens when AirDrop is active.
* **Tri-Tier Hybrid Connectivity** — works over the same Wi-Fi network, over the phone's mobile hotspot, and across different networks via BLE desk proximity.
* **High-Throughput Streaming** — 4 MB socket buffers, `TCP_NODELAY`, and 1 MB streaming pipelines capable of **100+ MB/s** transfers.

---

## What's New in AirBridge 2.0 (Zero-App Architecture)

| Capability | AirBridge 1.0 (Legacy) | AirBridge 2.0 |
|---|---|---|
| **Phone Setup** | Custom APK must be installed & running | **None required (Native Quick Share)** |
| **Mac UI** | Standalone custom window | **Native Finder AirDrop Window** |
| **Wi-Fi Detection (Mode 1)** | Custom Bonjour / manual IP | **Native mDNS (`_FC9F5ED42C8A._tcp`)** |
| **Mobile Hotspot (Mode 2)** | Manual IP / app local hotspot | **Auto Gateway Detection & Unicast DNS-SD** |
| **Different Networks (Mode 3)** | Not supported | **BLE Desk Proximity (`0xFEF3`) + Auto P2P** |
| **Background Power** | Continuous listener socket | **0% CPU (Event-driven via Darwin notifications)** |
| **Peak Throughput** | ~20–30 MB/s | **100+ MB/s (Optimized TCP & 4 MB Buffers)** |

---

## How It Works

```
┌───────────────────────────────── macOS ─────────────────────────────────┐
│                                                                         │
│   Finder AirDrop Window ──(HTTPS/AWDL)──▶ AirBridge Mock AirDrop Peer   │
│                                                │                        │
│                                           (Quick Share)                 │
│                                                ▼                        │
└────────────────────────────────────────────────┼────────────────────────┘
                                                 │ Wi-Fi / SoftAP / BLE P2P
┌──────────────────────────── Android Phone ─────┼────────────────────────┐
│                                                ▼                        │
│       Native Quick Share Sheet ◀─────── (Incoming Transfer)             │
│       (No custom app required on Android!)                              │
└─────────────────────────────────────────────────────────────────────────┘
```

1. **Mac → Android**: Open Finder → **AirDrop**. Nearby Android phones appear automatically. Drag files onto the phone; accept on the phone's native Quick Share prompt.
2. **Android → Mac**: Open any file or photo on Android → tap **Share** → **Quick Share** → select your Mac. Accept on the Mac prompt (files save to `~/Downloads`).

---

## Tri-Tier Connection Modes

1. **Mode 1: Same Wi-Fi Network**
   - Discovers Android devices over local multicast DNS (`_FC9F5ED42C8A._tcp.local.`).
   - Maximum speed, lowest latency, zero interruption to your Mac's internet connection.
2. **Mode 2: Mobile Hotspot (Tethering / SoftAP)**
   - When the Mac joins the phone's mobile hotspot, AirBridge automatically detects the gateway IP (`192.168.43.1`, `172.x.x.x`) and sends a direct unicast DNS-SD probe to `gateway:5353`.
   - Bypasses Android's tethering multicast filters so the phone is discovered instantly.
3. **Mode 3: BLE Desk Proximity (Different Networks / 5G)**
   - When devices are on different networks or cellular data, AirBridge uses Bluetooth Low Energy (Service UUID `0xFEF3`) to detect the phone within desk proximity (`RSSI >= -70 dBm`).
   - Initiates an automated direct peer-to-peer Wi-Fi / WebRTC channel.

---

## 100+ MB/s Speed Configuration

AirBridge 2.0 has been tuned at the socket and buffer layer (4 MB buffers, `TCP_NODELAY`, 1 MB streaming blocks). To hit maximum link speed:
- **Use 5 GHz Wi-Fi**: Connect both devices to a 5 GHz or 6 GHz Wi-Fi band with **80 MHz or 160 MHz** channel width.
- **For Hotspot**: In your phone's Hotspot settings, switch **Speed & Compatibility / AP Band** from 2.4 GHz to **5 GHz**.
- **Android Power Save**: In Samsung / Pixel settings, ensure *Wi-Fi Power Saving Mode* is disabled during large transfers.

---

## Getting Started

### Build from Source
```bash
# Build the native AirBridge bridge
scripts/build-bridge.sh

# Or directly with Cargo
cd bridge && cargo build --release
```

### Run AirBridge
```bash
# Start AirBridge (runs on-demand with AirDrop)
./bridge/target/release/airbridge

# Check setup, network interfaces, and reach
./bridge/target/release/airbridge doctor

# Optional CLI flags:
#   --auto-accept          Accept incoming transfers without confirmation dialog
#   --download-dir <path>  Customize destination folder (default: ~/Downloads)
#   --always-on            Run continuously instead of sleeping when AirDrop is Off
```

---

Built for and tested on a **Moto G54 5G (Android 15)** and a **MacBook Air M4
(macOS 27)**.

| | |
|---|---|
| Directions | Android → Mac and Mac → Android, simultaneously over one connection |
| Content | Any file type, multiple files, whole folders, Unicode names, empty files, multi-GB files |
| Network | Phone Wi-Fi hotspot (no router, no internet); any LAN without client isolation as fallback |
| Security | Paired devices only; ECDH + ECDSA (P-256) authenticated handshake, AES-256-GCM, one-time QR codes |
| Integrity | SHA-256 of every file, computed over the stored data before it is published |
| Robustness | Streaming with bounded memory, cancel, automatic reconnect and **resume** after interruptions |

## Status (honest summary)

* ✅ Both apps build; protocol implemented identically in Swift and Kotlin
  (24/24 interop checks, shared crypto test vectors).
* ✅ Automated tests: Swift 29/29, Kotlin 24/24, on-phone instrumented 4/4.
* ✅ Real-device transfers in both directions over the phone's hotspot, up to 1 GB,
  all SHA-256 verified; interrupted transfers resume in both directions.
* ✅ Speed with the hotspot set to **5 GHz**: **31–43 MB/s** (100 MB in under 3 s,
  1 GB phone → Mac in 29 s). On the default **2.4 GHz** band it is only 5–6.5 MB/s, so
  choose *Hotspot → Speed & compatibility → 5 GHz*. Large Mac → phone transfers
  sometimes dip to 12–16 MB/s because of Wi-Fi link variance (raw TCP shows the same
  dips).
* ✅ First manual UI pass with the user: QR pairing and phone → Mac transfer worked. Bugs
  found there are fixed: iCloud placeholder files hung a send, and a phone button label
  wrapped. See `docs/testing.md`. The macOS app is ad-hoc signed and not notarized.

Details: [`docs/testing.md`](docs/testing.md), [`docs/performance.md`](docs/performance.md).

## Download

Get the latest **[release](../../releases/latest)**:

* **Android:** `AirBridge-1.1.0.apk` (Android 10 or newer). Open it on the phone and allow
  installing from your browser or file manager.
* **macOS:** `AirBridge-1.1.0.dmg` (macOS 14 or newer, Apple silicon). Drag to
  Applications. On first launch: right-click → **Open** (the app is not notarized).

Then follow [Pairing](#pairing).

## How it works

```
 Moto G54 (hotspot "AP")  ◀──── Wi-Fi, no router ────▶  MacBook Air (joined to hotspot)
 AirBridge Android app         TCP :47820, encrypted     AirBridge.app (always listening)
```

1. The Mac app listens on port 47820 and advertises itself via Bonjour.
2. **Pairing (once):** the Mac shows a QR code containing its address, a one-time
   5-minute code and its public-key fingerprint. The phone scans it, both devices
   authenticate each other, the Mac user approves, and both store each other's key.
3. **Later:** tap the paired Mac on the phone (or it reconnects automatically after an
   interruption). Drop files on the Mac window or pick/share them on the phone.

More: [`docs/architecture.md`](docs/architecture.md), protocol:
[`protocol/SPEC.md`](protocol/SPEC.md), why the hotspot:
[`docs/networking-feasibility.md`](docs/networking-feasibility.md),
[`docs/security.md`](docs/security.md).

## Repository

```
protocol/            SPEC.md (source of truth) + shared test vectors
android/core/        Pure Kotlin protocol/crypto/transfer engine (+ JVM CLI, JVM tests)
android/app/         Android app: Compose UI, MediaStore/SAF storage, foreground service
macos/Sources/AirBridgeCore/  Swift protocol/crypto/transfer engine (Network.framework)
macos/Sources/AirBridge/      SwiftUI macOS app
macos/Sources/airbridge-cli/  Swift CLI (interop tests, benchmarks)
macos/Tests/         Swift tests
scripts/             build, interop, device, benchmark and checksum scripts
benchmarks/          Machine-readable results (results.jsonl)
docs/                Architecture, feasibility, security, testing, performance, install, troubleshooting
```

## Prerequisites

* macOS with Xcode (Swift 6) — tested with Xcode 27.0.
* JDK 17+ and the Android SDK (platform 37.1, build-tools 35+) — tested with JDK 21,
  AGP 9.4.1, Gradle 9.7.1 (wrapper included), Kotlin 2.4.21.
* For installing on the phone: USB debugging enabled (see installation guide).

## Build and install

```bash
# Android (debug APK; for a signed release APK see docs/installation.md)
cd android && ./gradlew :app:assembleDebug
~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk

# macOS app (+ optional disk image)
scripts/build-macos-app.sh && open macos/dist/AirBridge.app
scripts/make-dmg.sh 1.1.0
```

Full instructions, permissions, signing and Gatekeeper notes:
[`docs/installation.md`](docs/installation.md).

## Pairing

1. On the phone: **Settings → Network & internet → Hotspot & tethering → Wi-Fi
   hotspot** → on. Recommended: *Speed & compatibility* → **5 GHz**.
2. On the Mac: join that hotspot from the Wi-Fi menu (no internet is needed).
3. Mac: open AirBridge → **Pair New Device** (QR code appears).
4. Phone: open AirBridge → **Connect to Mac** → scan the QR code.
5. Mac: confirm **Pair** after checking that both screens show the same 6-digit
   verification number.

Without a camera: phone → *Connect to Mac* → **Enter code** (address, port 47820 and
the `XXXXX-XXXXX` code shown on the Mac). The opposite direction (phone shows a code,
Mac connects) is under phone **Receive** / Mac **Connect to Device…**.

## Sending and receiving

* **Mac → phone:** drag files or folders onto the AirBridge window, or **Choose Files…**.
  They arrive in the phone's **Download/AirBridge** folder.
* **Phone → Mac:** **Send files** / folder button, or **Share → AirBridge** from any app.
  They arrive in `~/Downloads/AirBridge` (configurable).
* Each transfer shows progress, current and average MB/s (measured), time left, and a
  cancel button. Finished transfers say *SHA-256 verified*.
* Existing files are never overwritten (`photo (1).jpg`).
* Settings: device name, destination folder, *Ask before receiving*, chunk size.

## Testing

```bash
cd macos && swift test                       # 29 tests
cd android && ./gradlew :core:test           # 24 tests
scripts/interop-test.sh                      # Swift ⇄ Kotlin, 24 checks
```

Device and benchmark scripts: [`docs/testing.md`](docs/testing.md).

## Performance methodology

Throughput is bytes transferred divided by wall time from the receiver's accept to the
final verification (`scripts/benchmark-transfers.sh`); every run's output file is
compared with the source. Loopback runs show the engine ceiling (~1 GB/s on the M4);
device runs show the real Wi-Fi rate. Results: [`docs/performance.md`](docs/performance.md),
raw data: [`benchmarks/results.jsonl`](benchmarks/results.jsonl).

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md). The most common problems are
a router with *client isolation* (use the hotspot) and a 2.4 GHz hotspot (switch to 5 GHz).

## Security notes

Only devices you paired can connect; the QR code holds no permanent secret; all traffic
is encrypted and authenticated; incoming names are sanitised and files are only published
after verification. The handshake is a custom construction from standard primitives and
has not been independently audited — see [`docs/security.md`](docs/security.md).

## Current limitations

* Resume works while the sending app keeps running; if the sender app is restarted the
  transfer must be sent again. Partial files are deleted after 24 h.
* The Mac can only be on one Wi-Fi network: on the phone hotspot it has internet only if
  the hotspot shares mobile data.
* Hotspot addresses can change between sessions; AirBridge reconnects via last address
  and Bonjour/NSD, otherwise scan a new QR code.
* macOS app is not sandboxed, not notarized; Android release APK must be signed with
  your own key.
* No Wi-Fi Direct (macOS has no public API for it).

## Contributing and security

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems
privately as described in [SECURITY.md](SECURITY.md).

## License

MIT — see [`LICENSE`](LICENSE).
