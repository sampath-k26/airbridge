# AirBridge Protocol — Version 1

This document is the single source of truth for the wire protocol implemented by
`android/core` (Kotlin) and `macos/Sources/AirBridgeCore` (Swift). Any change here
must be mirrored in both implementations and in `protocol/test-vectors/`.

All integers are **big-endian**. "b64" is standard Base64 with padding (RFC 4648 §4).
JSON is UTF-8, RFC 8259. Unknown JSON fields MUST be ignored (forward compatibility).

## 1. Roles and topology

* **Listener** — accepts a TCP connection (shows the QR code / pairing code).
* **Dialer** — opens the TCP connection (scans the QR code / types the code).

Roles only matter for the handshake. After authentication the connection is a
symmetric, full-duplex **session**: either peer may offer files at any time.

Default TCP port: **47820** (configurable; a listener that cannot bind it picks an
ephemeral port and advertises the real one in the QR code / Bonjour record).

Optional discovery: DNS-SD service type `_airbridge._tcp`, TXT keys
`v=1`, `id=<device id>` (see §3.1), `n=<display name>`. Discovery is advisory only;
it never grants trust.

## 2. Cryptographic primitives

| Purpose              | Algorithm |
|----------------------|-----------|
| Identity key         | ECDSA P-256, signatures over SHA-256, DER-encoded (X9.62 `Ecdsa-Sig-Value`) |
| Ephemeral key        | ECDH P-256; shared secret = 32-byte big-endian X coordinate |
| Public key encoding  | DER SubjectPublicKeyInfo (`SPKI`, 91 bytes for P-256) |
| KDF                  | HKDF-SHA256 (RFC 5869) |
| Record AEAD          | AES-256-GCM, 128-bit tag |
| Pairing proof        | HMAC-SHA256 |
| File integrity       | SHA-256 over the complete file contents |

### 2.1 Device identity

Each install generates one long-term P-256 identity key pair, stored in Android
Keystore / macOS Keychain. **Fingerprint** = `SHA-256(SPKI)`. **Device id** = lowercase
hex of the first 16 bytes of the fingerprint (32 hex chars). User-facing fingerprint
display = first 8 bytes as hex in groups of 4 (`ab12 cd34 ef56 7890`).

## 3. Pairing material

### 3.1 Pairing code

A listener in pairing mode holds **at most one** active pairing code:

* 10 characters from the Crockford Base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
  (≈50 bits), generated with a CSPRNG.
* Displayed as `XXXXX-XXXXX`. Input normalisation: uppercase, remove `-` and spaces,
  map `O→0`, `I→1`, `L→1`.
* Lifetime **5 minutes**; **single use**; invalidated after **5 failed** proofs.
* HMAC key = ASCII bytes of the normalised 10-character code.

### 3.2 QR payload

A URI (never contains long-term secrets):

```
airbridge://pair?v=1&h=<host>[,<host>...]&p=<port>&c=<code>&f=<b64url fingerprint, no padding>&n=<urlencoded name>
```

`h` lists the listener's candidate IPv4 addresses (most likely first). `f` lets the
dialer authenticate the listener cryptographically; the code `c` lets the listener
authenticate the dialer. The code expires in 5 minutes and is single-use.

Manual pairing (no camera) uses host + port + code only; the listener is then
authenticated by its code proof (§5.4) and both screens show a 6-digit
**verification number** (SAS) that the user compares.

## 4. Framing

### 4.1 Handshake frames (plaintext)

```
u32 length | length bytes of UTF-8 JSON      (1 ≤ length ≤ 16384)
```

### 4.2 Records (encrypted, after the handshake)

```
u32 length | ciphertext (length bytes, includes the 16-byte GCM tag)
```

`17 ≤ length ≤ MAX_RECORD_CIPHERTEXT = 4 MiB + 1024 + 16`. Anything else is a
protocol violation (close with `malformed`).

Nonce (12 bytes) = `00 00 00 00 || u64 counter`. Each direction has its own key and
its own counter starting at 0 and incremented after every record. AAD is empty.
A record that fails authentication terminates the session (no retries, no skipping) —
this provides replay, reordering and truncation-within-stream protection.
Counters MUST NOT wrap (a session is closed long before 2^64 records).

Record plaintext:

| byte 0 | rest |
|--------|------|
| `0x01` CONTROL | UTF-8 JSON object, ≤ 1 MiB |
| `0x02` DATA | `u32 stream` + ≥ 1 byte of file data (≤ 4 MiB) |

## 5. Handshake

```
Dialer                                   Listener
  hello ─────────────────────────────────▶
  ◀───────────────────────────── server_hello      (plaintext frames)
            [derive keys]
  ◀───────────────────────────── server_auth       (CONTROL records)
  client_auth ───────────────────────────▶
  ◀───────────────────────────── auth_ok | error
```

Handshake must finish within **15 s** (plus up to **90 s** waiting for the user to
approve a new pairing on the listener).

### 5.1 `hello` (dialer → listener)

```json
{"type":"hello","proto":1,"minProto":1,"eph":"<b64 SPKI>","nonce":"<b64 32 bytes>",
 "pairing":true,"app":"AirBridge-Android/1.0"}
```

`pairing` is true when the dialer intends to use a pairing code.

### 5.2 `server_hello` (listener → dialer)

```json
{"type":"server_hello","proto":1,"eph":"<b64 SPKI>","nonce":"<b64 32 bytes>"}
```

If no common version exists the listener sends
`{"type":"error","code":"unsupported_version","message":"..."}` and closes.

### 5.3 Key schedule

```
th  = SHA-256( "AirBridge/1" || u32 len(hello) || hello || u32 len(server_hello) || server_hello )
         -- hello / server_hello are the exact frame payload bytes
ss  = ECDH(eph_dialer, eph_listener)              -- 32 bytes
okm = HKDF-SHA256(ikm = ss, salt = th, info = "airbridge/1 session keys", L = 64)
k_d2l = okm[0..32]     -- dialer → listener record key
k_l2d = okm[32..64]    -- listener → dialer record key
sas = (u32 th[0..4]) mod 1_000_000, shown zero-padded to 6 digits
```

### 5.4 `server_auth` (listener → dialer, first CONTROL record)

```json
{"type":"server_auth","identity":"<b64 SPKI>","sig":"<b64 DER>","name":"MacBook Air",
 "platform":"macos","pairProof":"<b64 32 bytes, only if hello.pairing and a code is active>"}
```

* `sig` = ECDSA(identity, `"airbridge/1 server-auth" || th`)
* `pairProof` = HMAC(code, `"airbridge/1 pair-listener" || th || identity_spki`)

Dialer verification: signature MUST verify. Then the listener is trusted iff
(a) its fingerprint equals a stored paired fingerprint, or (b) it equals the QR `f`
value, or (c) the dialer has a manual code and `pairProof` verifies. Otherwise the
dialer aborts with `auth_failed`.

### 5.5 `client_auth` (dialer → listener)

```json
{"type":"client_auth","identity":"<b64 SPKI>","sig":"<b64 DER>","name":"moto g54",
 "platform":"android","pairProof":"<b64, only when pairing>"}
```

* `sig` = ECDSA(identity, `"airbridge/1 client-auth" || th`)
* `pairProof` = HMAC(code, `"airbridge/1 pair-dialer" || th || identity_spki`)

Listener verification: signature MUST verify. Then:
* fingerprint already paired → `auth_ok`.
* else `pairProof` verifies against the active code → code is consumed; the listener
  asks its user to approve "*name* wants to pair — verification *sas*" (≤ 90 s).
  Approve → store peer, `auth_ok`. Deny/timeout → `error pairing_rejected`.
* else → failed-attempt counter++, `error auth_failed`, close.

### 5.6 `auth_ok`

```json
{"type":"auth_ok","name":"MacBook Air","paired":true}
```

Both sides now store `{fingerprint, identity SPKI, name, platform, last address}`.

## 6. Session messages (CONTROL records)

All carry `"type"`. `transferId` is a UUID string chosen by the sender.

### 6.1 Keep-alive

`{"type":"ping"}` → `{"type":"pong"}`. Each peer sends a ping after 15 s without
sending anything; a session with no received record for **45 s** is dead.

### 6.2 `offer` (sender → receiver)

```json
{"type":"offer","transferId":"…","totalBytes":123,
 "files":[{"id":0,"path":"Photos/IMG 1.jpg","size":123,"mtime":1700000000000,"mime":"image/jpeg"}]}
```

* 1 ≤ files ≤ 5000; ids are unique non-negative ints within the offer.
* `path` is a relative, `/`-separated path (validated per §7). `size` ≥ 0.
  `mtime` in Unix ms or 0 if unknown. `mime` optional.

### 6.3 `accept` / `reject` (receiver → sender)

```json
{"type":"accept","transferId":"…","files":[{"id":0,"offset":0}]}
{"type":"reject","transferId":"…","code":"declined","message":"…"}
```

`offset` > 0 requests resume (§8). Files omitted from `accept.files` are skipped.

### 6.4 File stream (sender → receiver)

For each accepted file, in order:

1. `{"type":"file_begin","transferId":"…","fileId":0,"stream":7,"offset":0}`
   `stream` is a sender-chosen u32 unique within the session.
2. DATA records for `stream` carrying bytes `offset..size` in order.
3. `{"type":"file_end","transferId":"…","fileId":0,"sha256":"<64 lowercase hex>"}`
   `sha256` covers the **entire** file (bytes 0..size), including any resumed prefix.

The sender does not wait for acknowledgement before starting the next file.
Zero-byte files send `file_begin` and `file_end` with no DATA.

### 6.5 Per-file result (receiver → sender)

```json
{"type":"file_ok","transferId":"…","fileId":0,"name":"IMG 1 (1).jpg"}
{"type":"file_failed","transferId":"…","fileId":0,"code":"hash_mismatch","message":"…"}
```

The receiver checks the length, then computes SHA-256 **over the data read back from the
stored temp file** (so storage faults and resume errors are caught, not only network
errors), syncs it, and only then moves it to its final name. A transfer is complete for the sender when every accepted
file has a `file_ok`/`file_failed`; the receiver then sends
`{"type":"transfer_done","transferId":"…","ok":true}`.

### 6.6 `cancel`

`{"type":"cancel","transferId":"…","reason":"user"}` — either side. Sender stops
reading; receiver closes and **deletes** partial files for that transfer (explicit
cancel is not resumable).

### 6.7 `error`

`{"type":"error","code":"…","message":"…"}` — fatal; the sender closes the socket.

### 6.8 Error codes

`unsupported_version`, `malformed`, `auth_failed`, `pairing_rejected`,
`pairing_expired`, `declined`, `busy`, `invalid_path`, `insufficient_storage`,
`write_failed`, `read_failed`, `hash_mismatch`, `size_mismatch`, `cancelled`,
`resume_invalid`, `timeout`, `internal`.

## 7. Path validation (receiver, mandatory)

Applied to every `files[].path`; the same rules are tested by
`test-vectors/paths.json`.

1. Unicode NFC normalise.
2. Reject if: empty; > 1024 UTF-8 bytes; starts with `/`; contains `\`, NUL or any
   U+0000–U+001F / U+007F; matches `^[A-Za-z]:` (drive letter); > 32 components.
3. Split on `/`. For each component: reject if empty, `.` or `..`; replace each of
   `: * ? " < > |` with `_`; strip trailing spaces and dots; reject if now empty or
   > 255 UTF-8 bytes.
4. Re-join with `/`. The result is always relative and contained in the destination.

Name conflicts at the destination are resolved by appending ` (1)`, ` (2)`, … before the
extension of the **top-level** component (file or folder). Existing files are never
overwritten.

## 8. Resume

* A receiver that loses the connection mid-file keeps the partial temp file together
  with `{transferId, fileId, path, size, mtime, peer fingerprint, bytes written}`
  for 24 h.
* On reconnect the sender re-sends the same `offer` (same `transferId`).
* The receiver may answer `offset = bytes durably written` only if transferId, peer,
  path, size and mtime all match; otherwise offset 0. Offsets are never > size.
* `file_begin.offset` MUST equal the accepted offset; otherwise `resume_invalid`.
* The sender hashes the full file; the receiver hashes the full temp file — a resumed
  file is only accepted if the full SHA-256 matches.
* Every reconnect performs the full authenticated handshake (§5).

## 9. Limits and timeouts

| Item | Limit |
|---|---|
| Handshake frame | 16 KiB |
| CONTROL JSON | 1 MiB |
| DATA payload | 4 MiB |
| Files per offer | 5000 |
| Path | 1024 bytes, 32 components, 255 bytes per component |
| Handshake timeout | 15 s (+90 s user approval) |
| Idle timeout | 45 s without any record (pings every 15 s) |
| Pairing code | 5 min, single use, 5 failures |
