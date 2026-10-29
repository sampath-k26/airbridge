# Architecture

AirBridge operates as a high-performance native system bridge between **macOS AirDrop** (in Finder) and **Android Quick Share** (built into Google Play Services and Samsung One UI).

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

---

## Core Pillars

### 1. Zero-App System Sharing
* **Mac → Android**: Files are dropped directly into Finder's AirDrop window onto the Android device. AirBridge receives the AirDrop upload stream and transmits it to the phone via Quick Share.
* **Android → Mac**: Shared via the native Android Quick Share sheet. AirBridge receives the file on macOS, prompts the user via native system dialog, and writes directly to `~/Downloads`.

### 2. Tri-Tier Hybrid Connection Architecture
* **Mode 1 (Local Wi-Fi LAN)**: Direct mDNS resolution (`_FC9F5ED42C8A._tcp.local.`). Lowest latency, maximum local LAN throughput, zero interruption to internet or active connections.
* **Mode 2 (Mobile Hotspot AP)**: Unicast DNS-SD probe to the default gateway (`192.168.43.1:5353`). Resolves the phone even when Android SoftAP drops multicast packets.
* **Mode 3 (BLE Desk Proximity / Different Networks)**: Passive Bluetooth Low Energy scanner listening for Quick Share beacons (`0xFEF3`). Triggers when RSSI is >= -70 dBm (same desk proximity). Solves transfers when devices are on completely different Wi-Fi networks or cellular data.

### 3. On-Demand Lifecycle (No Continuous Background Tasks)
* Uses Darwin notification descriptors (`notify_register_file_descriptor`) watching `com.apple.sharingd.DiscoverableModeChanged` and `FinderAirDropChanged`.
* **When AirDrop is Off**: The bridge transitions to a dormant event-wait state (0% CPU, 0 network sockets, all Bonjour advertisements unregistered).
* **When AirDrop is On**: The bridge awakens, binds AWDL, starts discovery, and populates Finder with discovered Android devices.

---

## High-Throughput I/O Engine

* **4 MB Socket Buffers**: Sockets set `SO_RCVBUF` and `SO_SNDBUF` to 4 MiB, enabling TCP window scaling across multi-gigabit Wi-Fi 6/6E/7 channels.
* **`TCP_NODELAY`**: Disables Nagle's algorithm across all connections to prevent 40 ms delayed-ACK pauses.
* **1 MB Streaming Reader & Writer**: Replaces default 8 KB buffers with 1 MB buffered streams, eliminating NVMe/SSD context switches and blocking stalls.
