# Troubleshooting

### 1. Phone Not Showing Up in Finder's AirDrop

* **The phone's screen is off**: Android hides Quick Share discovery while the device is locked/sleeping. Unlock your phone and ensure the screen is awake.
* **Quick Share visibility is disabled**: On your phone, go to **Settings → Google → Quick Share** and ensure *Who can share with you* is set to **Everyone**.
* **AirDrop is disabled on your Mac**: In macOS Control Center or Finder, ensure AirDrop is set to **Contacts Only** or **Everyone** (not "No One" / Off).
* **Local Network permission blocked**: On your Mac, navigate to **System Settings → Privacy & Security → Local Network** and ensure `airbridge` is allowed.
* **Phone appears as "Android phone [number]"**: Some Android phones hide their device name in broadcast packets. Run `airbridge qr` and scan the QR code once with your phone's camera, or send a single file from the phone to the Mac; AirBridge will permanently remember its device name.

---

### 2. Slow Transfer Speeds (Below 100 MB/s)

* **Wi-Fi Band**: Check if either your phone or Mac is connected to the 2.4 GHz Wi-Fi band. 2.4 GHz has a physical limit of ~6–7 MB/s. Always connect to the **5 GHz or 6 GHz** band.
* **Router Channel Width**: In your router settings, ensure 5 GHz channel width is set to **80 MHz or 160 MHz** (enables 866–2400 Mbps PHY rates).
* **Hotspot Speed**: If using a phone mobile hotspot, switch the hotspot from 2.4 GHz to **5 GHz** in Android Hotspot settings.
* **Wi-Fi Power Saving**: On Samsung One UI or Pixel devices, turn off *Wi-Fi Power Saving Mode* in Advanced Wi-Fi settings during large file transfers.

---

### 3. Running Diagnostics

Run the diagnostic utility in your terminal:

```bash
airbridge doctor
```

It verifies:
1. macOS AirDrop discoverable state (`Everyone` / `Contacts Only`).
2. AWDL (`awdl0`) interface health.
3. Local Wi-Fi network detection.
4. Mobile hotspot gateway auto-detection.
5. Bluetooth Low Energy desk proximity scanner status.
