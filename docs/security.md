# Security

## AirBridge 2.0 Native Bridge Security Model

AirBridge 2.0 incorporates native system-level sharing security defenses:

1. **AirDrop Interface & Source Isolation**:
   - The mock AirDrop HTTPS listener on AWDL strictly enforces that incoming connections must originate from **this Mac's own loopback or `awdl0` link-local address**.
   - Connections from nearby third-party Macs are rejected immediately. This prevents neighboring machines from routing unauthorized transfers or probing the bridge.

2. **Strict Path Traversal Defense**:
   - All extracted filenames from AirDrop dvzip/cpio frames undergo sanitization via `safe_relative()`.
   - The parser enforces `Component::Normal` path segments, strictly rejecting `..`, absolute paths, root directories, and NUL bytes.
   - Symlinks and special files are dropped; only regular files and directories are written into the isolated spool directory.

3. **Consent & Verification**:
   - Incoming Quick Share transfers prompt the Mac user via a native macOS dialog displaying the sender name, filename, and authentication PIN.
   - Unsolicited files cannot be deposited into `~/Downloads` without explicit user interaction (unless the user explicitly enables `--auto-accept`).

4. **Private Key & Credential Permissions**:
   - Self-signed TLS private keys (`key.pem`) generated for AWDL listeners are locked with POSIX permissions `0600` (`-rw-------`). Only the running user can read the key.

5. **Spool Lifecycle & Automatic Purging**:
   - Upload streams are unpacked into uniquely tagged ephemeral spool folders under `~/Library/Caches/airbridge/<tag>`.
   - Spool folders are purged automatically upon transfer completion or error.

---

## AirBridge 1.0 Legacy Security Model

AirBridge treats every network as hostile. Being on the same Wi-Fi or hotspot grants
nothing: a device can exchange files only after an authenticated pairing that the user
initiated on both screens.

## Threat model

| Attacker | Capability | Defence |
|---|---|---|
| Passive eavesdropper on the Wi-Fi | Reads all packets | AES-256-GCM per record, keys from ephemeral ECDH (forward secrecy) |
| Active man-in-the-middle during pairing | Intercepts / modifies traffic | QR pairing: listener's public-key fingerprint in the QR is checked; manual pairing: both sides prove the one-time code bound to the handshake transcript + 6-digit verification number shown on both screens |
| Device on the same network | Connects to the open port | Unknown keys are rejected unless they prove the current one-time code; the user must approve every new pairing |
| Replay / reordering / truncation of records | Re-sends or drops captured records | Implicit per-direction 64-bit counter nonces; any authentication failure closes the session |
| Malicious paired peer | Sends crafted metadata | Strict JSON parsing, size limits, path sanitisation, never overwrites, temp files until SHA-256 verified |

Out of scope: a compromised phone or Mac (malware with the user's privileges), physical
access to an unlocked device, denial-of-service on the radio.

## Protocol (summary of `protocol/SPEC.md`)

* **Identity:** each install has a long-term ECDSA P-256 key.
  * Android: generated **inside Android Keystore** (`PURPOSE_SIGN`, non-exportable,
    hardware-backed where available).
  * macOS: CryptoKit key stored in the login **Keychain** as a generic-password item
    (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). If the Keychain is unavailable
    the app falls back to a `0600` file in Application Support.
* **Handshake (SIGMA-style):** ephemeral ECDH P-256 → HKDF-SHA256 over the transcript
  hash `th` → two directional AES-256-GCM keys. Each side signs
  `label || th` with its identity key, so signatures are bound to this exact session
  (no reflection or replay of auth messages).
* **Pairing code:** 10 Crockford-Base32 characters (≈ 50 bits) from the CSPRNG,
  **single use, 5-minute lifetime, invalidated after 5 wrong proofs**. Proofs are
  `HMAC(code, label || th || identity)`, so a captured proof is useless in another session.
* **QR content:** host(s), port, protocol version, the one-time code, the listener's
  public-key *fingerprint* and a display name. **No long-term secret is ever in the QR.**
* **Trust on success:** both sides store the peer's public key. Later connections are
  authenticated by signature against the stored key; no code is needed.

### Why not TLS?

TLS was the first choice. It was not used because:

1. macOS Network.framework TLS needs a `SecIdentity` (certificate + private key in the
   Keychain). Creating a self-signed X.509 certificate requires a hand-written ASN.1
   encoder or a third-party package, and keychain identity handling differs between
   signed and ad-hoc-signed builds.
2. Android's Keystore keys would need a custom `X509KeyManager`, and both sides would
   need custom trust managers that pin raw keys anyway.
3. Pairing must still bind a short code to the session (channel binding), which needs
   TLS exporters on both stacks.

The custom handshake uses only standard primitives (ECDH, ECDSA, HKDF, HMAC,
AES-GCM) from the platform crypto libraries (CryptoKit, Conscrypt/BoringSSL), with
cross-implementation test vectors in `protocol/test-vectors/handshake.json`. **It has
not had an independent cryptographic review**; a production release should get one or
migrate to TLS 1.3 with raw public keys or a Noise pattern (`Noise_XXpsk3`).

### Manual pairing caveat

Without the QR fingerprint, the listener is authenticated by its code proof. An active
attacker who intercepts the handshake could try to brute-force the 50-bit code offline
from a captured proof within its 5-minute lifetime. The **6-digit verification number**
shown on both devices detects a man-in-the-middle; users should compare it. QR pairing
does not have this weakness.

## Transfer safety

* Incoming paths are validated (`SPEC §7`): NFC normalised; absolute paths, `..`, `.`,
  empty components, backslashes, control characters, drive letters, over-long names and
  deep trees are rejected; `: * ? " < > |` are replaced. Test vectors:
  `protocol/test-vectors/paths.json`.
* Files are written to a temporary file (macOS: `.airbridge-partial/` inside the
  destination; Android: MediaStore `IS_PENDING` item or `name.airbridge-part` in the
  chosen folder) and only published after the **SHA-256 of the data read back from
  storage** matches the sender's hash.
* Existing files are **never overwritten**: macOS uses `renamex_np(RENAME_EXCL)` and picks
  `name (1).ext` on conflict; Android MediaStore assigns unique names; the SAF path checks
  and renames.
* Limits: handshake frame 16 KiB, control message 1 MiB, data record 4 MiB, 5000 files
  per offer, path 1024 bytes. Timeouts: 15 s handshake, 90 s pairing approval, 45 s idle.
* Receivers check free space before accepting and map ENOSPC to a clear error.
* Optional "Ask before receiving" prompts for every offer; otherwise only **paired**
  devices can send, and only while the app is connected.

## Data handling

* No analytics, no accounts, no network calls other than to the paired device.
* Logs contain no keys, codes or file contents. The Android debug build logs transfer
  results (names, sizes) under the tag `AirBridgeTest`; release builds do not include the
  debug control service.
* Android `allowBackup=false` and data-extraction rules exclude keys, paired devices and
  history from cloud backup and device transfer.
* Forgetting a device deletes its stored public key; the device must pair again.

## Debug-only test hook

`DebugControlService` exists **only in the debug build** (`src/debug`). It is exported
but protected by `android.permission.DUMP`, which only the ADB shell holds, so other apps
cannot use it. It is absent from release APKs.
