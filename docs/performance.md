# Performance

All numbers are **measured** (2026-10-14). Raw data: `benchmarks/results.jsonl`
(pre-fix data: `benchmarks/results-pre-memory-fix.jsonl`). Every transfer's output was
compared byte-for-byte or by SHA-256 with its source; all runs listed passed.

## Method

* `scripts/benchmark-transfers.sh loopback 1024 3` — 1 GiB random file, Mac loopback,
  Swift→Swift and JVM→Swift, chunk sizes 64 KiB / 256 KiB / 1 MiB / 4 MiB, 3 runs each.
  CPU time and peak RSS from `/usr/bin/time -l`.
* `scripts/benchmark-transfers.sh device 100` inside `scripts/hotspot-session.sh` —
  100 MiB each way between the phone app (debug build, MediaStore destination) and the
  Mac CLI over the phone's hotspot; then 1 GiB each way at 1 MiB chunks.
* Throughput = payload bytes / time from the receiver's `accept` until the sender saw
  the final verification (`transfer_done`) — i.e. includes hashing and `fsync`.
* Android crypto speed and an on-phone encrypted loopback session: instrumented test
  `DeviceTest` on the Moto G54.

## 1. Real devices over the phone hotspot (the number that matters)

### 1a. 5 GHz hotspot (recommended setting)

Link: Moto G54 hotspot set to **5 GHz → channel 36, 802.11ac, 80 MHz, MCS 9, 433 Mbps
PHY**, Mac at −45 dBm (same room).

| Size | Direction | Result | Verified |
|---|---|---|---|
| 100 MiB | Mac → phone | **38.5 MB/s** (2.7 s) | ✅ |
| 100 MiB | Phone → Mac | **43.0 MB/s** (2.4 s) | ✅ |
| 1 GiB | Phone → Mac | **36.9 MB/s** (29.1 s) | ✅ |
| 1 GiB | Mac → phone | 15.9 / 12.1 / 31.5 MB/s (three runs) | ✅ all |

That is **≈ 6–7× the 2.4 GHz numbers** below.

**Why large Mac → phone transfers vary.** The spread happens on the link, not in AirBridge:

* Raw TCP without AirBridge (`nc` on the phone, 1 GiB) reached 34.6–37.3 MB/s on
  average. Its 5-second throughput dipped from ~45 to ~15 MB/s several times, and it
  was the same whether the data went to `/dev/null`, shared storage (`/sdcard/Download`)
  or `/data`. So neither phone storage nor the protocol sets the ceiling.
* In a slow AirBridge run (~8 MB/s, measured while also polling the phone over adb
  every 2 s), the app's threads used about 3 % CPU. It was waiting for data, not
  processing it.
* In a fast run (31.5 MB/s), the phone's TCP receive queue stayed near 0, so the app
  read as fast as data arrived. The Mac's send queue stayed full (~2.6 MB), so the
  Mac produced data as fast as the link took it.
* The app ran in the `foreground` cpuset during the transfers, so it was not
  CPU-throttled. Phone battery temperature was 35 °C.

Likely causes are 5 GHz rate adaptation and interference, which nothing on either device
controls. Expect 30–40 MB/s typically, with occasional slower runs.

### 1b. 2.4 GHz hotspot (the phone's default)

Link: Moto G54 hotspot, **2.4 GHz, 802.11n, 20 MHz, MCS 7 → 72 Mbps PHY**
(as configured on the phone; reported by the Mac's Wi-Fi status).

| Size | Chunk | Mac → phone | Phone → Mac |
|---|---|---|---|
| 100 MiB | 64 KiB | 5.3 MB/s (20.0 s) | 6.3 MB/s (16.7 s) |
| 100 MiB | 256 KiB | 4.8 MB/s (22.0 s) | 6.5 MB/s (16.0 s) |
| 100 MiB | 1 MiB | 5.6 MB/s (18.6 s) | 6.1 MB/s (17.1 s) |
| 100 MiB | 4 MiB | 4.8 MB/s (21.7 s) | 5.9 MB/s (17.6 s) |
| **1 GiB** | 1 MiB | **5.1 MB/s (211.6 s)** | **4.6 MB/s (232.0 s)** |
| 100 MiB (first test) | 1 MiB | 5.7 MB/s | 6.3 MB/s |

MB = 10⁶ bytes. Variation between runs is ±15 % (shared 2.4 GHz band, phone battery
at 2–10 % and charging during the tests).

**Interpretation.** 72 Mbps PHY gives at most ≈ 7–7.5 MB/s of TCP payload after Wi-Fi and
TCP overheads; AirBridge reaches 65–90 % of that. Chunk size makes **no measurable
difference** on this link — the radio is the bottleneck by more than 10× (see §3). Switching
the hotspot to **5 GHz** removes that bottleneck (§1a).

### Resume on the real devices

| Interruption | Bytes re-sent after reconnect | Result |
|---|---|---|
| Mac sender killed after 9 s (Mac → phone, 100 MiB) | 58.7 MB of 104.9 MB | phone reconnected automatically, SHA-256 match |
| Mac receiver killed after 9 s (phone → Mac, 100 MiB) | 54.5 MB of 104.9 MB | phone reconnected and resumed its queued send, SHA-256 match |

## 2. Engine ceiling on the Mac (loopback, 1 GiB, 3 runs each, mean)

| Sender → receiver | Chunk | MB/s | Sender CPU s | Receiver CPU s | Sender peak RSS | Receiver peak RSS |
|---|---|---|---|---|---|---|
| Swift → Swift | 64 KiB | 887 | 0.92 | 1.27 | 27 MB | 15 MB |
| Swift → Swift | 256 KiB | 967 | 0.77 | 0.86 | 21–26 MB | 15 MB |
| Swift → Swift | **1 MiB** | **1005** | **0.72** | **0.78** | 23–27 MB | 19–20 MB |
| Swift → Swift | 4 MiB | 956 | 0.80 | 0.85 | 37 MB | 36–38 MB |
| JVM → Swift | 64 KiB | 594 | 2.2 | 1.3 | 360 MB* | 15 MB |
| JVM → Swift | 256 KiB | 531 | 2.5 | 0.87 | 280 MB* | 16 MB |
| JVM → Swift | 1 MiB | 229 | 5.3 | 0.84 | 226 MB* | 20 MB |
| JVM → Swift | 4 MiB | 174 | 6.8 | 0.89 | 213 MB* | 37 MB |

\* JVM RSS is dominated by the default heap sizing of a desktop JVM, not by retained data.

* **Swift engine: ~1 GB/s with < 40 MB peak memory** for a 1 GiB file — memory is
  bounded by chunk size × in-flight window, independent of file size.
* The desktop JVM sender slows down with large records (desktop JDK's AES-GCM
  implementation). This does **not** apply to Android, whose crypto provider
  (Conscrypt/BoringSSL) gets *faster* with larger records (§3).

### Bug found by benchmarking

The first run showed **peak RSS ≈ 1 GB for a 1 GB transfer** (sender 1050 MB, receiver
890 MB): Foundation's `FileHandle.read` returns autoreleased buffers that are not freed
inside long-running async tasks. Switching file I/O to POSIX `read`/`write` (`PosixIO`)
fixed it (now 20–40 MB) and raised throughput from 911 to 1005 MB/s at 1 MiB.

## 3. Phone capability (Moto G54, instrumented tests)

| Record size | AES-256-GCM encrypt | SHA-256 |
|---|---|---|
| 64 KiB | 356 MB/s | 1342 MB/s |
| 256 KiB | 553 MB/s | 1363 MB/s |
| **1 MiB** | **756 MB/s** | 1377 MB/s |
| 4 MiB | 774 MB/s | 1386 MB/s |

* Full encrypted session phone → phone over `127.0.0.1` into MediaStore (64 MiB, both
  ends on the same CPU): **79.3 MB/s**.
* App memory (TOTAL PSS) while transferring 1 GiB each way: **160 MB peak**, the same as
  its idle baseline (159.7 MB) — no growth with file size.

**Default chunk size = 1 MiB:** on the phone it reaches 98 % of the 4 MiB crypto speed
with a quarter of the buffer memory; on the Mac it is the fastest setting with the lowest
CPU; on Wi-Fi all sizes perform the same.

## 4. Integrity verification time

The receiver re-reads and hashes each stored file before publishing it.

| Device | Measured | 1 GiB verification |
|---|---|---|
| MacBook Air M4 | read + SHA-256 at ~2.8 GB/s (file in page cache) | **0.39 s** |
| Moto G54 | SHA-256 compute at ~1.37 GB/s (storage read not separately measured) | ≈ 0.8 s + storage read |

The sender hashes while reading, so it adds no extra pass.

## 5. Parallel streams

Not implemented: one TCP connection already saturates the Wi-Fi link (§1) and reaches
~1 GB/s on loopback (§2). Multiple files/transfers in both directions already share the
connection concurrently. Parallel connections would add complexity without a measurable
benefit on this hardware.

## Reproduce

```bash
cd macos && swift build -c release --product airbridge-cli && cd ../android && ./gradlew :core:installDist && cd ..
scripts/benchmark-transfers.sh loopback 1024 3
HOTSPOT_SSID=… HOTSPOT_PASS=… LINK="description" scripts/hotspot-session.sh scripts/benchmark-transfers.sh device 100
```
