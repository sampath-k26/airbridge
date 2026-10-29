//! Find Quick Share receivers on the local Wi-Fi and Mobile Hotspot interfaces.
//!
//! Discovers devices advertised via standard multicast mDNS, and actively probes
//! the mobile hotspot gateway via unicast DNS-SD so phones connected as mobile hotspots
//! are detected even when multicast packets are dropped by Android SoftAP.

use std::collections::{HashMap, HashSet};
use std::net::Ipv4Addr;
use std::time::{Duration, Instant};

use anyhow::Result;
use base64::Engine;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use tokio::sync::mpsc;

use crate::{ble, hotspot, qr};

const SERVICE: &str = "_FC9F5ED42C8A._tcp.local.";
const LOST_GRACE: Duration = Duration::from_secs(30);

#[derive(Debug)]
pub enum Event {
    Found { ip: Ipv4Addr, name: Option<String>, addr: String, qr: bool },
    DeskProximityFound { endpoint_id: String, name: Option<String>, rssi: i32 },
    DeskProximityLost { endpoint_id: String },
    Lost { ip: Ipv4Addr },
}

pub fn start(qr: qr::Key) -> Result<mpsc::Receiver<Event>> {
    let daemon = ServiceDaemon::new()?;
    let browse = daemon.browse(SERVICE)?;
    let (tx, rx) = mpsc::channel(32);
    let ble_scanner = ble::BLEProximityScanner::new(ble::DEFAULT_DESK_RSSI_THRESHOLD);
    let mut ble_rx = ble_scanner.start()?;

    tokio::spawn(async move {
        let _daemon = daemon;
        let mut by_ip: HashMap<Ipv4Addr, HashSet<String>> = HashMap::new();
        let mut leaving: HashMap<Ipv4Addr, Instant> = HashMap::new();
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        let mut hotspot_tick = tokio::time::interval(Duration::from_secs(6));
        let mut last_hotspot_ip: Option<Ipv4Addr> = None;

        loop {
            tokio::select! {
                Some(ble_ev) = ble_rx.recv() => {
                    match ble_ev {
                        ble::BLEEvent::DeviceNear(dev) => {
                            let _ = tx.send(Event::DeskProximityFound {
                                endpoint_id: dev.endpoint_id,
                                name: dev.name,
                                rssi: dev.rssi,
                            }).await;
                        }
                        ble::BLEEvent::DeviceLeft(id) => {
                            let _ = tx.send(Event::DeskProximityLost {
                                endpoint_id: id,
                            }).await;
                        }
                    }
                }
                ev = browse.recv_async() => {
                    let ev = match ev {
                        Ok(ev) => ev,
                        Err(_) => return,
                    };
                    let out = match ev {
                        ServiceEvent::ServiceResolved(info) => {
                            let Some(ip) = info.get_addresses_v4().into_iter().next().copied() else { continue };
                            if local_ipv4s().contains(&ip) {
                                continue;
                            }
                            let n = info.get_property_val_str("n");
                            if n.is_some_and(is_computer) {
                                log::debug!("skipping computer {} at {ip}", info.get_fullname());
                                continue;
                            }
                            let (name, scanned) = n.map(|n| endpoint(n, &qr)).unwrap_or_default();
                            by_ip.entry(ip).or_default().insert(info.get_fullname().to_string());
                            leaving.remove(&ip);
                            Event::Found { ip, name, addr: format!("{ip}:{}", info.get_port()), qr: scanned }
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            let Some(ip) = by_ip.iter_mut().find_map(|(ip, names)| names.remove(&fullname).then_some(*ip)) else {
                                continue;
                            };
                            if !by_ip[&ip].is_empty() {
                                continue;
                            }
                            by_ip.remove(&ip);
                            leaving.insert(ip, Instant::now());
                            continue;
                        }
                        _ => continue,
                    };
                    if tx.send(out).await.is_err() {
                        return;
                    }
                }
                _ = hotspot_tick.tick() => {
                    // Check if connected to a mobile hotspot
                    if let Some((gw, _iface)) = hotspot::get_default_gateway() {
                        if !local_ipv4s().contains(&gw) && (hotspot::is_likely_hotspot(gw) || last_hotspot_ip == Some(gw)) {
                            // Probe hotspot gateway directly
                            match hotspot::probe_unicast_mdns(gw).await {
                                Ok(peer) => {
                                    let (name, scanned) = peer.raw_n.as_deref().map(|n| endpoint(n, &qr)).unwrap_or_default();
                                    last_hotspot_ip = Some(gw);
                                    leaving.remove(&gw);
                                    let _ = tx.send(Event::Found {
                                        ip: gw,
                                        name,
                                        addr: format!("{}:{}", gw, peer.port),
                                        qr: scanned,
                                    }).await;
                                }
                                Err(e) => {
                                    log::debug!("hotspot probe on {gw}: {e}");
                                }
                            }
                        }
                    } else if let Some(old_gw) = last_hotspot_ip.take() {
                        leaving.insert(old_gw, Instant::now());
                    }
                }
                _ = tick.tick() => {
                    let gone: Vec<_> = leaving.iter().filter(|(_, t)| t.elapsed() >= LOST_GRACE).map(|(ip, _)| *ip).collect();
                    for ip in gone {
                        leaving.remove(&ip);
                        if tx.send(Event::Lost { ip }).await.is_err() {
                            return;
                        }
                    }
                }
            }
        }
    });

    Ok(rx)
}

/// Device type 3 (laptop/desktop) in bits 1..3 of the endpoint info's first byte.
fn is_computer(n: &str) -> bool {
    let b = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(n.trim_end_matches('='));
    b.ok().and_then(|b| b.first().copied()).is_some_and(|f| (f >> 1) & 7 == 3)
}

/// Name, and whether device scanned our QR code, from the base64url endpoint info.
pub fn endpoint(n: &str, qr: &qr::Key) -> (Option<String>, bool) {
    let parse = || {
        let b = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(n.trim_end_matches('=')).ok()?;
        let mut rest = b.get(17..)?;
        let mut name = None;
        if b[0] & 0x10 == 0 {
            let (&len, tail) = rest.split_first()?;
            name = String::from_utf8(tail.get(..len as usize)?.to_vec()).ok().filter(|n| !n.is_empty());
            rest = &tail[len as usize..];
        }
        while let [t, len, tail @ ..] = rest {
            let Some(value) = tail.get(..*len as usize) else { break };
            if *t == 1 {
                if value == qr.token() {
                    return Some((name, true));
                }
                let hidden = qr.name(value);
                let ours = hidden.is_some();
                return Some((name.or(hidden), ours));
            }
            rest = &tail[value.len()..];
        }
        Some((name, false))
    };
    parse().unwrap_or_default()
}

pub fn local_ipv4s() -> Vec<Ipv4Addr> {
    let mut out = Vec::new();
    unsafe {
        let mut ifs: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifs) != 0 {
            return out;
        }
        let mut cur = ifs;
        while !cur.is_null() {
            let ifa = &*cur;
            if !ifa.ifa_addr.is_null() && (*ifa.ifa_addr).sa_family as i32 == libc::AF_INET {
                let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                out.push(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)));
            }
            cur = ifa.ifa_next;
        }
        libc::freeifaddrs(ifs);
    }
    out
}
