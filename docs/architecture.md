# Architecture

```
┌──────────── macOS (Swift) ────────────┐            ┌──────────── Android (Kotlin) ───────────┐
│ AirBridge.app (SwiftUI)               │            │ app (Jetpack Compose)                   │
│  AppModel ── listener, dial, jobs     │            │  SessionManager ── listen, dial, jobs   │
│  Views: drop zone, pairing QR, …      │            │  UI: home, connect (QR scan), receive   │
│                                       │            │  TransferService (foreground, locks)    │
│ AirBridgeCore (library)               │  TCP 47820 │  storage: MediaStore / SAF, content URIs│
│  Protocol  Messages, PathSanitizer,   │◀──────────▶│  security: Android Keystore identity    │
│            Pairing (code, QR URI)     │ AES-256-GCM│                                         │
│  Security  Crypto, Identity, Trust    │  records   │ core (pure Kotlin/JVM library)          │
│  Transport ByteStream (Network.fw),   │            │  protocol, crypto, transport (sockets), │
│            SecureChannel, Handshake   │            │  transfer Session, SpeedMeter, storage  │
│  Transfer  Session, SpeedMeter        │            │  + JVM CLI for interop tests            │
│  Storage   FileSystemStorage, PosixIO │            └─────────────────────────────────────────┘
│  Discovery Listener (+Bonjour), Browser│
│ airbridge-cli (interop + benchmarks)  │      protocol/SPEC.md + test-vectors = source of truth
└───────────────────────────────────────┘
```

## Layers

| Layer | Responsibility | Swift | Kotlin |
|---|---|---|---|
| Protocol | Constants, typed errors, message schema, path rules, pairing code / QR URI | `Protocol/` | `core/protocol` |
| Security | ECDH/ECDSA/HKDF/HMAC, record cipher, identity storage, trust store | `Security/` (CryptoKit, Keychain) | `core/crypto` (JCA), `app/security` (Keystore) |
| Transport | TCP stream, handshake frames, encrypted record channel with backpressure | `Transport/` (Network.framework) | `core/transport` (java.net sockets, writer thread) |
| Transfer | Offers, streaming, hashing, resume, cancel, progress | `Transfer/Session.swift` | `core/transfer/Session.kt` |
| Storage | Temp files, verification read-back, unique final names, partial bookkeeping | `FileSystemStorage` | `FileSystemStorage` (JVM), `MediaStoreStorage`, `TreeStorage` |
| App | Connection lifecycle, job queue, reconnect, UI state, history | `AirBridge/Models/AppModel.swift` | `app/transfer/SessionManager.kt` |
| UI | Native views | SwiftUI | Jetpack Compose (Material 3) |

The two core libraries are deliberately parallel (same file/class names where
possible) so that a change to the spec maps 1:1 to both. No code is shared across
languages; the spec and the test vectors are the contract, and
`scripts/interop-test.sh` runs the Swift and Kotlin engines against each other.

## Connection model

* **Session = one TCP connection = one paired peer**, full duplex. After the handshake
  either side may send; one listener/dialer distinction only matters for setup.
* Typical setup: the Mac always listens (port 47820, Bonjour `_airbridge._tcp`); the
  phone dials it by scanning the QR code (first time) or by tapping the paired Mac
  (later; last address or NSD discovery). The reverse (phone listens via *Receive*,
  Mac dials via *Connect to Device…*) is also supported.
* Each transfer is an `offer` → `accept`/`reject` → per-file `file_begin` / DATA /
  `file_end` → `file_ok|file_failed` → `transfer_done` exchange; several transfers can run
  concurrently in both directions (each file has its own stream id).

## Data path and performance design

* **Streaming, bounded memory.** Sender reads `chunkSize` (default 1 MiB) at a time,
  hashes it, encrypts it into one record and queues it. At most 8 MiB of records may be
  queued (`maxInFlight`); further sends suspend until the network drains (backpressure).
  The receiver writes each record directly to the temp file. Measured peak RSS for a
  1 GB transfer on macOS: ~20–40 MB.
* **No Base64, no compression, no per-chunk reopen.** File data travels as raw bytes in
  binary records.
* **POSIX I/O on macOS.** Foundation's `FileHandle.read` returns autoreleased buffers
  that accumulate inside async tasks; `PosixIO` reads into owned buffers (this fixed a
  1 GB-RSS problem found by the benchmark).
* **Control messages never wait for capacity** (`urgent`), so a reader can always reply
  even when both directions are saturated — this prevents a cross-peer deadlock.
* **Integrity.** Sender hashes while reading; receiver re-reads the stored file after the
  last byte and compares SHA-256 before publishing it.
* **Android power.** While a transfer runs the foreground service holds a low-latency
  Wi-Fi lock and a partial wake lock; both are released when idle.

## Resume

* Interrupted receives keep the temp file + JSON metadata (peer, path, size, mtime).
* The sender keeps the job (same `transferId`) and retries when the session returns.
  The dialer side reconnects automatically for 2 minutes after an unexpected drop if any
  transfer was interrupted.
* On re-offer the receiver answers with the stored length as `offset` only if the peer,
  path, size and mtime match; the sender validates the offset and sends the remainder.
  The final SHA-256 covers the whole file.
* Not supported: resuming after the *sending app* restarts (the job list is in memory),
  and partial files older than 24 h are deleted.

## Threading

* **Swift:** structured concurrency. Session reader runs in a detached task; sends are
  `async`; network callbacks bridge via continuations; UI state lives on `@MainActor`.
  Locks (`ABLock`, an `os_unfair_lock`) are never held across `await`.
* **Kotlin:** one reader thread and one writer thread per session; transfers run in
  coroutines on `Dispatchers.IO`; UI observes `StateFlow`s.
