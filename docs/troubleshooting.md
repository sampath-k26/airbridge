# Troubleshooting

### "Could not connect" / the phone never reaches the Mac

1. **Are both devices on the same network?** The Mac's Wi-Fi menu must show the phone's
   hotspot (or the same Wi-Fi as the phone). AirBridge never uses mobile data or the
   internet.
2. **Router client isolation.** Many home routers block device-to-device traffic. Test:
   `ping <phone-ip>` from the Mac. If it fails, use the phone's hotspot instead (this was
   the case on the router used for development — see `networking-feasibility.md`).
3. **Is AirBridge open on the Mac?** The Mac listens only while the app runs. Its window
   header shows `waiting on <ip> port 47820`.
4. **macOS Local Network permission** denied → System Settings → Privacy & Security →
   Local Network → enable AirBridge.
5. **Firewall:** allow incoming connections for AirBridge.
6. The address changed (new hotspot session): tap the paired Mac to reconnect — AirBridge
   tries the last address and Bonjour discovery — or scan a new QR code.

### Pairing errors

| Message | Meaning / fix |
|---|---|
| *The pairing code expired or was already used* | Codes last 5 minutes and work once. Click **New Code** on the Mac. |
| *Authentication failed* | Wrong code, a different Mac answered, or the Mac's key changed (app reinstalled / Keychain reset). Remove the device on both sides and pair again. |
| *Pairing was declined* | Someone clicked Decline (or the 90 s approval window passed). |
| Verification numbers differ | **Do not pair.** Something is intercepting the connection. |

### Slow transfers

* The hotspot band is the main factor. On the Moto G54: **Hotspot → Speed &
  compatibility → 5 GHz** (2.4 GHz caps at ≈ 6 MB/s; measured).
* Keep the devices within a few metres; walls and 2.4 GHz congestion lower the rate.
* Check the Mac's link: hold ⌥ and click the Wi-Fi menu → *Tx Rate*.
* Chunk size (Settings) has no measurable effect on Wi-Fi; keep 1 MiB.

### Transfer interrupted

* The connection dropped (Wi-Fi off, out of range, app killed). The partial file is kept
  for 24 h. When the devices reconnect — the phone retries automatically for 2 minutes,
  or tap the paired device — the same transfer resumes from where it stopped and is
  fully re-verified.
* Restarting the **sending** app forgets its queue; send the files again (the receiver
  then starts a new copy).

### "Integrity check failed"

The received data did not match the sender's SHA-256 and was discarded (nothing is
published). Retry. Repeated failures point to failing storage on the receiver.

### "Not enough free space"

The receiver checks free space before accepting. Free up space or choose another
destination folder.

### Where are my files?

* Android: **Files → Downloads → AirBridge** (or the folder chosen in Settings).
  Name conflicts get ` (1)`, ` (2)`, … — nothing is ever overwritten.
* macOS: `~/Downloads/AirBridge` (Settings → *Save files to*). Use **Show in Finder**
  on a finished transfer.

### Developer diagnostics

* Android logs: `adb logcat -s AirBridge AirBridgeNsd AirBridgeTest` (no keys, codes or
  file contents are logged).
* macOS: run `macos/dist/AirBridge.app/Contents/MacOS/AirBridge` from Terminal.
* Protocol-level debugging: the CLIs (`airbridge-cli`, `airbridge-jvm`) print JSON
  events; `scripts/interop-test.sh` checks Swift ⇄ Kotlin compatibility.
