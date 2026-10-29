# Security

AirBridge enforces a strict defense-in-depth security architecture designed specifically for cross-platform AirDrop ↔ Quick Share interoperability.

---

## Security Model & Defenses

### 1. AirDrop Interface & Source Isolation
* The mock AirDrop HTTPS listener on AWDL strictly enforces that incoming connections must originate from **this Mac's own loopback or `awdl0` link-local address**.
* Connections from nearby third-party Macs are rejected immediately. This prevents neighboring machines on the same AWDL channel from routing unauthorized transfers or probing the bridge.

### 2. Strict Path Traversal Defense
* All extracted filenames from AirDrop dvzip/cpio frames undergo sanitization via `safe_relative()`.
* The parser enforces `Component::Normal` path segments, strictly rejecting `..`, absolute paths, root directories, and NUL bytes.
* Symlinks and special files are dropped; only regular files and directories are written into the isolated spool directory.

### 3. Consent & Verification
* Incoming Quick Share transfers prompt the Mac user via a native macOS dialog displaying the sender name, filename, and authentication PIN.
* Unsolicited files cannot be deposited into `~/Downloads` without explicit user interaction (unless the user explicitly enables `--auto-accept`).

### 4. Private Key & Credential Permissions
* Self-signed TLS private keys (`key.pem`) generated for AWDL listeners are locked with POSIX permissions `0600` (`-rw-------`). Only the running user account can read the key.

### 5. Spool Lifecycle & Automatic Purging
* Upload streams are unpacked into uniquely tagged ephemeral spool folders under `~/Library/Caches/airbridge/<tag>`.
* Spool folders are purged automatically upon transfer completion or error.
