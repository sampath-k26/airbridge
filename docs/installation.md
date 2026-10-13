# Installation

## Requirements

| | Minimum | Tested |
|---|---|---|
| Android | 10 (API 29) | Moto G54 5G, Android 15 |
| macOS | 14 Sonoma | MacBook Air M4, macOS 27.0.1 |
| Build: Android | JDK 17+, Android SDK platform 37.1 (compileSdk), build-tools 35+ | JDK 21, AGP 9.4.1, Gradle 9.7.1, Kotlin 2.4.21 |
| Build: macOS | Xcode with Swift 6 toolchain | Xcode 27.0, Swift 6.4 |

No accounts, cloud services or paid tools are needed.

## Android app

### Build

```bash
cd android
./gradlew :app:assembleDebug            # → app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` must point at the SDK (`sdk.dir=/Users/<you>/Library/Android/sdk`);
Android Studio creates it automatically.

### Install on the Moto G54

1. On the phone: **Settings → About phone →** tap **Build number** 7 times.
2. **Settings → System → Developer options → USB debugging: on.**
3. Connect the USB cable, accept *Allow USB debugging* (tick *Always allow*).
4. On the Mac:

```bash
~/Library/Android/sdk/platform-tools/adb devices          # shows ZD22…  device
~/Library/Android/sdk/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

### Permissions (asked at the moment they are needed)

| Permission | Why |
|---|---|
| Notifications (Android 13+) | Progress notification for transfers that continue with the screen off |
| Camera | Scanning the pairing QR code (only on the Connect screen) |
| Nearby Wi-Fi devices (13+) / Location (10–12) | Only for the optional in-app Local-Only Hotspot |
| (automatic) Internet, network/Wi-Fi state, wake lock, foreground service | Local TCP connection, Wi-Fi lock during transfers |

No storage permission is requested: files you send are chosen with the system picker,
and received files go to **Download/AirBridge** through MediaStore (or a folder you pick
in Settings).

### Release build

```bash
./gradlew :app:assembleRelease          # → app-release-unsigned.apk (R8-minified, ~4 MB)
```

Sign it with your own keystore (never commit it):

```bash
keytool -genkeypair -v -keystore ~/airbridge-release.jks -alias airbridge -keyalg EC -groupname secp256r1 -validity 10000
$ANDROID_HOME/build-tools/37.0.0/zipalign -f 4 app/build/outputs/apk/release/app-release-unsigned.apk /tmp/aligned.apk
$ANDROID_HOME/build-tools/37.0.0/apksigner sign --ks ~/airbridge-release.jks --out AirBridge.apk /tmp/aligned.apk
```

A release APK cannot be installed over a debug install signed with a different key —
uninstall first (`adb uninstall com.mahi.airbridge`; this deletes pairings).

## macOS app

```bash
scripts/build-macos-app.sh              # → macos/dist/AirBridge.app (release, ad-hoc signed)
open macos/dist/AirBridge.app
```

Or copy `AirBridge.app` to `/Applications`.

* **Signing:** the app is **ad-hoc signed** (no Apple Developer ID) and **not notarized**.
  On the Mac that built it, it opens normally. On another Mac, Gatekeeper blocks it:
  right-click → **Open** → **Open**, or *System Settings → Privacy & Security → Open
  Anyway*. Distribution to other people would need a Developer ID certificate and
  `xcrun notarytool`.
* **Local Network permission:** the first time AirBridge connects, macOS asks to allow
  it to find devices on the local network — choose **Allow** (System Settings → Privacy &
  Security → Local Network).
* **Keychain:** the device identity is stored in the login keychain. Because each
  ad-hoc build has a new code signature, macOS may ask once to let a rebuilt AirBridge
  access its key; choose *Always Allow*.
* Firewall: if the macOS firewall is on, allow incoming connections for AirBridge when
  asked (the phone connects to the Mac's port 47820).
* Not sandboxed: AirBridge writes to the folder you choose (default `~/Downloads/AirBridge`).

## Command-line peers (developers)

```bash
cd macos && swift build -c release --product airbridge-cli        # Swift CLI
cd android && ./gradlew :core:installDist                          # JVM CLI: core/build/install/airbridge-jvm/bin/airbridge-jvm
```

Both print one JSON object per line and accept `listen|dial`, `--send`, `--expect`,
`--chunk`, `--code`, `--uri`, `--state`, `--dir` (see `scripts/interop-test.sh`).

## First connection

See README → *Pairing*. In short: phone hotspot on → Mac joins it → Mac:
**Pair New Device** → phone: **Connect to Mac** → scan → confirm the verification number.
