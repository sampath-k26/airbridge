# Testing

Results below are from 2026-10-14. **Real-device** = Moto G54 5G (Android 15) ⇄
MacBook Air M4 (macOS 27.0.1) over the phone's Wi-Fi hotspot, no router, no internet
used by AirBridge. **Simulated** = loopback/JVM runs on the Mac.

## How to run

```bash
# Swift unit + loopback integration tests (29)
cd macos && swift test

# Kotlin core unit + loopback integration tests (24), JVM
cd android && ./gradlew :core:test

# Android instrumented tests on a connected phone (4) — keep the app installed afterwards:
cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true

# Swift ⇄ Kotlin protocol interop (24 checks)
cd macos && swift build --product airbridge-cli && cd ../android && ./gradlew :core:installDist && cd ..
scripts/interop-test.sh

# Real-device scripts (phone on USB for adb; the Mac joins the hotspot for the test and
# always rejoins the home network afterwards):
HOTSPOT_SSID="<hotspot>" HOTSPOT_PASS="<password>" scripts/hotspot-session.sh scripts/device-wireless-test.sh WORKDIR MAC_DIR PHONE_DIR
HOTSPOT_SSID=… HOTSPOT_PASS=… scripts/hotspot-session.sh scripts/device-resume-test.sh WORKDIR FILE
HOTSPOT_SSID=… HOTSPOT_PASS=… scripts/hotspot-session.sh scripts/device-resume-test-p2m.sh WORKDIR 100
HOTSPOT_SSID=… HOTSPOT_PASS=… scripts/hotspot-session.sh scripts/benchmark-transfers.sh device 100

# Checksums
scripts/generate-test-files.sh OUT [--large]
scripts/verify-checksums.sh SRC DST
```

Device tests drive the real app through the **debug-only** `DebugControlService`
(`adb shell am start-foreground-service …`), so they run with the phone locked.

## Results

| Suite | Kind | Result |
|---|---|---|
| Swift `AirBridgeCoreTests` | unit + loopback | **29 / 29 passed** (interruption tests stress-run 10×) |
| Kotlin `:core:test` | unit + loopback (JVM) | **24 / 24 passed** (`TransferTest` stress-run 5×; the full suite also runs in CI on every pull request) |
| Android instrumented (`DeviceTest`) | on the phone | **4 / 4 passed** |
| `interop-test.sh` (Swift ⇄ Kotlin, both roles, QR + manual pairing, bidirectional) | loopback | **24 / 24 checks passed** |

### Coverage by requirement

| Requirement | Where verified |
|---|---|
| Shared vectors (paths, key schedule, MACs, AES-GCM records, ECDSA) | `VectorTests` (Swift) and `VectorTest` (Kotlin) on the same JSON files |
| Valid / invalid metadata, unsupported version, oversized frames | `testUnsupportedVersionAndOversizedFrame`, `unsupportedVersionAndOversizedFrame` |
| Malformed frames | `testMalformedRecordClosesSession`, `malformedRecordClosesSession` |
| Tampered / replayed / reordered records | `testRecordTamperAndReplayRejected`, `recordTamperReorderReplayRejected` |
| Unauthorized peers, wrong / expired / declined codes, fingerprint mismatch | 7 Swift + 5 Kotlin auth tests |
| Zero-byte, 1 KB, 1 MB, Unicode names, binary, folders | `testTransferVariety`, `transferVariety`, interop corpus |
| Filename conflicts (never overwrite) | `testNameConflictsNeverOverwrite`; real device: second copy saved as `name (1).ext` |
| Path traversal / unsafe names | `testUnsafePathsRejected`, `unsafePathsRejected`, `paths.json` |
| Corrupt data on disk → hash mismatch, nothing published | `testCorruptionIsDetectedByHash`, `corruptionOnDiskDetected` |
| Disk full / insufficient space | `testDiskFullAbortsTransfer`, `testInsufficientCapacityRejectsOffer`, `diskFullAndCapacity` |
| Connection loss + resume | `testResumeAfterConnectionLoss`, `resumeAfterConnectionLoss`; real device both directions (below) |
| Invalid resume offsets | `testInvalidResumeOffsetFromPeerIsRejected`, `invalidResumeOffsetFromPeerRejected` |
| User cancellation (partials removed) | `testCancelBySenderRemovesPartial`, `cancelRemovesPartial` |
| Simultaneous transfers both directions | `testBidirectionalSimultaneousTransfers`, `bidirectionalSimultaneous` |
| Android Keystore identity, MediaStore write/resume/verify | `DeviceTest` on the phone |
| SHA-256 source vs destination | every script (`verify-checksums.sh`, `sha256sum` on the phone) |

### Real-device tests performed

| Test | Network | Result |
|---|---|---|
| Router path (home router) | home router | ❌ blocked by router client isolation (ARP fails both ways) |
| Hotspot reachability, 60 s link stability | phone hotspot 2.4 GHz | ✅ |
| 11-file corpus (Unicode, folders, empty files) both directions | USB `adb reverse` tunnel | ✅ all hashes match; duplicates saved as `(1)` |
| 100 MB Mac → phone / phone → Mac | hotspot | ✅ 5.7 / 6.3 MB/s, SHA-256 match |
| Chunk-size benchmark 64 KiB–4 MiB, 100 MB each way | hotspot | ✅ 8/8 verified, 4.8–6.5 MB/s |
| 1 GiB each way | hotspot | ✅ 5.1 MB/s (Mac → phone, 211.6 s) and 4.6 MB/s (phone → Mac, 232.0 s), both verified; phone app memory flat at 160 MB PSS |
| macOS app process (GUI build) | loopback | ✅ listens on 47820 and runs the handshake (unpaired peer refused with `auth_failed`); Bonjour advertisement needs the user to allow *Local Network* access (same code advertises correctly from the CLI) |
| Mac sender killed mid-transfer → restart | hotspot | ✅ phone auto-reconnected; resent 58.7 MB of 104.9 MB; hash match |
| Mac receiver killed mid-transfer → restart | hotspot | ✅ phone reconnected and resumed its queued send; resent 54.5 MB; hash match |
| Release (R8) APK launch | — | ✅ cold start 1.06 s, no crash |
| Final binaries, 100 MiB each way (after the last fix) | hotspot | ✅ 5.2 MB/s Mac → phone, 6.2 MB/s phone → Mac, both verified |
| 100 MiB each way | hotspot **5 GHz** (802.11ac, 433 Mbps) | ✅ 38.5 MB/s Mac → phone, 43.0 MB/s phone → Mac, verified |
| 1 GiB each way | hotspot 5 GHz | ✅ phone → Mac 36.9 MB/s; Mac → phone 15.9 / 12.1 / 31.5 MB/s in three runs (link variance, see performance.md §1a); all verified |
| Raw TCP baseline (no AirBridge), 1 GiB Mac → phone | hotspot 5 GHz | 34.6–37.3 MB/s on average, dipping to ~15 MB/s at times |

### Manual UI test with the user (2026-10-14)

| Step | Result |
|---|---|
| Mac app home, pairing sheet with QR code, approval dialog | ✅ rendered correctly; the address in the QR updated to the hotspot IP |
| Phone home, *Connect to Mac*, camera QR scan | ✅ scanned on first try |
| Pairing approval on both sides, same 6-digit number shown | ✅ (583263 on both) |
| Phone → Mac, a 1.1 MB photo chosen in the system picker | ✅ arrived in `~/Downloads/AirBridge`, *verified (SHA-256)*, 5.1 MB/s |
| Mac → phone, a 14.7 MB PDF chosen with *Choose Files…* | ❌ stuck at 0 %. The PDF was an iCloud placeholder (`dataless`) and the hotspot had no internet → **fixed**: such files are now detected before sending (`CloudFileTests`) |
| Phone UI bug: *Connect to Mac* button label wrapped onto two lines | **fixed** |
| Phone UI: several paired devices with the same name were indistinguishable | **fixed**: rows now show a key prefix and pairing date |
| Mac app blocked at launch by a Keychain prompt after a rebuild | documented (troubleshooting) |
| Time from QR scan to the Mac's approval dialog | ⚠️ about 70 s; cause not established (likely the one-time macOS Local Network prompt) |

### Bug found by CI (2026-10-14)

The first GitHub Actions run failed `resumeAfterConnectionLoss` on the slower Linux runner.
Cause (Kotlin engine only): when a session closed while a data record was being written,
the failed write was treated as a storage error and **deleted the resume partial**. Fixed
in `Session.failTransfer`, with a deterministic regression test
(`writeFailingDuringCloseKeepsPartial`, which fails without the fix). The Swift engine was
not affected, because it clears incoming transfers before closing files.

### Release artifacts (v1.0.0)

| Artifact | Check | Result |
|---|---|---|
| `AirBridge-1.0.0.apk` (signed, R8) | installed on the Moto G54, QR-less pairing with code over USB (`adb forward`), 20 MiB Mac → phone | ✅ paired, SHA-256 match, 31 MB/s; no crashes |
| `AirBridge-1.0.0.dmg` | `hdiutil verify`, mounted, `codesign --verify --deep` on the app inside | ✅ |

## Not tested / limitations

* **v1.1.0 UI redesign:** the new Mac window was reviewed in a screenshot by the user (dark mode, history
  data). The redesigned Android home screen compiles but has not been seen on a phone yet; nor have
  light mode on the Mac or an active transfer in the new list.

* **UI partly verified** (above). Drag-and-drop onto the Mac window, Settings screens on
  both sides, the Share sheet and transfers of folders through the UI were not exercised
  manually.
* Android: files picked from a cloud provider (e.g. Google Drive) are downloaded by that
  provider when read; without internet such a send may stall like the iCloud case. Not
  handled yet.
* The in-app Local-Only Hotspot was not measured (see `networking-feasibility.md`).
* Wi-Fi switched off on the phone mid-transfer (tested instead by killing the Mac
  process, which produces the same connection loss on the phone).
* Android activity recreation / app backgrounding during a transfer were not exercised
  manually; transfers run in the foreground service and the device tests ran with the
  screen off.
