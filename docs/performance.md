# Performance & 100+ MB/s Optimization Guide

## Why Did Previous Transfers Cap at ~20 MB/s?

In standard Wi-Fi configurations without socket and pipeline tuning, transfers are often throttled around 15–20 MB/s due to four bottlenecks:
1. **Small TCP Socket Buffers (Bandwidth-Delay Product bottleneck)**: Default macOS/BSD socket buffers (64–128 KB) throttle TCP window scaling on high-throughput links.
2. **Nagle's Algorithm (Delayed ACKs)**: Delayed-ACK timer (up to 40 ms) paused small control and stream frames.
3. **Unbuffered 8 KB Reads & Small Synchronous Disk Writes**: Processing data through default 8 KB `BufReader` and unbuffered `std::fs::File` forced thousands of kernel context switches and blocked Tokio worker threads.
4. **2.4 GHz Wi-Fi / Hotspot Band Limitation**: 2.4 GHz Wi-Fi has a physical PHY limit of 72 Mbps (max ~5–7 MB/s TCP goodput).

---

## Architectural Speed Optimizations (Applied)

1. **4 MB Socket Buffers (`SO_RCVBUF` / `SO_SNDBUF`)**:
   Expanded socket buffers allow the TCP sliding window to fill the entire multi-gigabit pipe on 802.11ax/be Wi-Fi.
2. **`TCP_NODELAY` Enabled**:
   Disables Nagle's algorithm across all listener and peer connections, streaming 1 MiB chunks immediately without ACK latency.
3. **1 MiB Stream Buffer (`BufReader::with_capacity(1024 * 1024)`)**:
   Replaces default 8 KiB buffer, eliminating ~95% of kernel context switches during multi-gigabyte transfers.
4. **1 MiB Buffered File I/O (`BufWriter::with_capacity(1024 * 1024)`)**:
   Batches disk writes to NVMe/SSD, preventing disk I/O pauses from stalling the network stream.

---

## How to Consistently Reach 100+ MB/s Across All 3 Modes

### Mode 1: Local Wi-Fi Network
* **Connect to 5 GHz or 6 GHz SSID**:
  - Connect both Mac and phone to the 5 GHz/6 GHz band (never 2.4 GHz).
* **Router Channel Width**:
  - In your router admin page, ensure the 5 GHz channel width is set to **80 MHz or 160 MHz** (enables 866–2402 Mbps PHY rates).
* **Android Intelligent Wi-Fi**:
  - In Samsung/Pixel settings: turn off *Wi-Fi Power Saving Mode* and ensure battery saver is disabled during transfers.

### Mode 2: Mobile Hotspot (SoftAP)
* **Switch Hotspot to 5 GHz**:
  - On your Android phone: go to **Settings → Network & Internet → Hotspot & tethering → Wi-Fi Hotspot → Speed & Compatibility (or AP Band) → Select 5 GHz**.
  - Default 2.4 GHz caps at ~6 MB/s; switching to 5 GHz immediately unlocks 40–100+ MB/s.

### Mode 3: Desk Proximity (BLE + Auto P2P)
* **Direct 5 GHz Wi-Fi Direct Channel**:
  - Local-Only Hotspot and Wi-Fi Direct negotiate high-bandwidth 5 GHz channels when in close proximity (RSSI >= -65 dBm).
  - Keep phone and Mac within 1–2 meters on the desk for maximum MIMO MCS rates.
