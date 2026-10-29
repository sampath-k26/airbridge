//! Mode 3: Bluetooth Low Energy (BLE) Proximity Scanner for macOS.
//!
//! Scans for Android Quick Share BLE advertisements (Service UUID 0xFEF3).
//! Filters by RSSI (desk proximity threshold, e.g. >= -70 dBm).
//! Allows detecting nearby Android devices even when both devices are on completely
//! different Wi-Fi networks (or phone is on 5G/cellular) with no shared router or hotspot.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use tokio::sync::mpsc;

pub const QUICK_SHARE_BLE_SERVICE_UUID: &str = "FEF3";
pub const DEFAULT_DESK_RSSI_THRESHOLD: i32 = -70; // -40 to -70 dBm is desk range (~1-2 meters)

#[derive(Debug, Clone)]
pub struct DiscoveredBLEDevice {
    pub name: Option<String>,
    pub endpoint_id: String,
    pub rssi: i32,
    pub raw_service_data: Vec<u8>,
    pub last_seen: Instant,
}

#[derive(Debug)]
pub enum BLEEvent {
    DeviceNear(DiscoveredBLEDevice),
    DeviceLeft(String),
}

/// Parse Google Quick Share BLE Service Data payload (UUID 0xFEF3).
///
/// Format:
/// Byte 0: Header / Version / Flags
///   - Bits 0..2: Version (typically 0 or 1)
///   - Bit 3: Visibility (0 = visible with name, 1 = hidden)
///   - Bits 4..7: Device Type (1=Phone, 2=Tablet, 3=Laptop)
/// Bytes 1..4: Salt / Rotating token
/// Bytes 5..: Encrypted Metadata Key or Length-prefixed Device Name
pub fn parse_quickshare_ble_payload(data: &[u8]) -> Option<(String, Option<String>)> {
    if data.len() < 5 {
        return None;
    }
    let header = data[0];
    let is_hidden = (header & 0x08) != 0;
    let endpoint_id = format!("{:02x}{:02x}{:02x}{:02x}", data[1], data[2], data[3], data[4]);

    let mut name = None;
    if !is_hidden && data.len() > 6 {
        let name_len = data[5] as usize;
        if data.len() >= 6 + name_len && name_len > 0 {
            if let Ok(parsed_name) = std::str::from_utf8(&data[6..6 + name_len]) {
                name = Some(parsed_name.to_string());
            }
        }
    }

    Some((endpoint_id, name))
}

/// Simulated / FFI CoreBluetooth monitor for Quick Share beacons.
pub struct BLEProximityScanner {
    desk_rssi_threshold: i32,
    discovered: Arc<Mutex<HashMap<String, DiscoveredBLEDevice>>>,
}

impl BLEProximityScanner {
    pub fn new(desk_rssi_threshold: i32) -> Self {
        Self {
            desk_rssi_threshold,
            discovered: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Starts scanning and sends proximity events over the channel.
    pub fn start(&self) -> Result<mpsc::Receiver<BLEEvent>> {
        let (tx, rx) = mpsc::channel(32);
        let discovered = self.discovered.clone();

        tokio::spawn(async move {
            let mut check_interval = tokio::time::interval(Duration::from_secs(3));
            loop {
                check_interval.tick().await;

                // Evict devices not seen in the last 15 seconds
                let mut expired = Vec::new();
                {
                    let mut map = discovered.lock().unwrap();
                    for (id, dev) in map.iter() {
                        if dev.last_seen.elapsed() > Duration::from_secs(15) {
                            expired.push(id.clone());
                        }
                    }
                    for id in &expired {
                        map.remove(id);
                    }
                }

                for id in expired {
                    let _ = tx.send(BLEEvent::DeviceLeft(id)).await;
                }
            }
        });

        Ok(rx)
    }

    /// Record a BLE advertisement received by CoreBluetooth.
    pub fn on_advertisement(&self, raw_data: &[u8], rssi: i32, tx: &mpsc::Sender<BLEEvent>) {
        if rssi < self.desk_rssi_threshold {
            return; // Out of desk proximity range
        }

        if let Some((endpoint_id, name)) = parse_quickshare_ble_payload(raw_data) {
            let device = DiscoveredBLEDevice {
                name,
                endpoint_id: endpoint_id.clone(),
                rssi,
                raw_service_data: raw_data.to_vec(),
                last_seen: Instant::now(),
            };

            let is_new = {
                let mut map = self.discovered.lock().unwrap();
                let prev = map.insert(endpoint_id.clone(), device.clone());
                prev.is_none()
            };

            if is_new {
                let _ = tx.try_send(BLEEvent::DeviceNear(device));
            }
        }
    }
}
