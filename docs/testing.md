# Testing & Verification Guide

## Automated Testing

AirBridge includes unit tests for the archive extractors, QR decoders, and discovery engines:

```bash
# Run all unit and integration tests
cargo test

# Run specific module tests
cargo test archive::tests
cargo test discovery::tests
cargo test qr::tests
```

---

## Live Diagnostics

Verify your local environment and device reachability in real time:

```bash
cargo run --release -- doctor
```

It validates:
* **macOS AirDrop State**: Reads `com.apple.sharingd` preference (`Everyone` / `Contacts Only`).
* **AWDL Status**: Verifies `awdl0` network interface and IPv6 link-local reachability.
* **Mode 1 (Wi-Fi LAN)**: Checks active mDNS listeners.
* **Mode 2 (Hotspot AP)**: Identifies if the active network is a mobile hotspot and tests unicast DNS-SD responses.
* **Mode 3 (Desk Proximity)**: Verifies the BLE scanner is actively receiving `0xFEF3` beacons.

---

## Testing AirDrop Uploads (Without Phone)

To test the macOS Finder AirDrop half without requiring a physical phone:

```bash
cargo run --release -- --test-peer
```

This registers a `"AirBridge Test"` receiver directly into Finder's AirDrop window. Files dropped on it will be saved to your `~/Downloads` folder, validating the AWDL listener, TLS handshake, dvzip/cpio extraction, and Finder UI integration.
