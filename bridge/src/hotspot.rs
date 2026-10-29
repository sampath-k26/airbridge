//! Detects if Mac is connected to an Android hotspot (SoftAP) and discovers Quick Share devices
//! on the hotspot gateway even if multicast mDNS is filtered by Android tethering firewall.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;
use anyhow::{Context, Result};
use tokio::net::UdpSocket;

/// Query default IPv4 gateway address and interface.
pub fn get_default_gateway() -> Option<(Ipv4Addr, String)> {
    // 1. Try scutil State:/Network/Global/IPv4
    if let Ok(output) = std::process::Command::new("/usr/sbin/scutil")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(b"show State:/Network/Global/IPv4\n");
            }
            child.wait_with_output()
        })
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut router = None;
        let mut iface = None;
        for line in stdout.lines() {
            let line = line.trim();
            if line.starts_with("Router :") {
                router = line.split(':').nth(1).and_then(|s| s.trim().parse::<Ipv4Addr>().ok());
            } else if line.starts_with("PrimaryInterface :") {
                iface = line.split(':').nth(1).map(|s| s.trim().to_string());
            }
        }
        if let (Some(r), Some(i)) = (router, iface) {
            return Some((r, i));
        }
    }

    // 2. Fallback to netstat -rn -f inet
    if let Ok(output) = std::process::Command::new("netstat")
        .args(["-rn", "-f", "inet"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 4 && parts[0] == "default" {
                if let Ok(ip) = parts[1].parse::<Ipv4Addr>() {
                    let iface = parts.last().unwrap_or(&"en0").to_string();
                    return Some((ip, iface));
                }
            }
        }
    }

    None
}

/// Checks if gateway IP looks like a mobile hotspot / SoftAP.
/// Common Android hotspot subnets: 192.168.43.0/24, 192.168.44.0/24, 192.168.49.0/24, 172.20.10.0/24, 172.31.x.x
pub fn is_likely_hotspot(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    match (octets[0], octets[1], octets[2]) {
        (192, 168, 43..=49) => true,
        (172, 20, 10) => true,
        (172, 16..=31, _) => true,
        _ => false,
    }
}

/// Discovered hotspot phone's Quick Share parameters.
#[derive(Debug, Clone)]
pub struct HotspotPeer {
    pub ip: Ipv4Addr,
    pub port: u16,
    pub raw_n: Option<String>,
}

/// Probe target gateway via unicast DNS-SD on UDP port 5353 for _FC9F5ED42C8A._tcp.local.
pub async fn probe_unicast_mdns(gateway: Ipv4Addr) -> Result<HotspotPeer> {
    let mut packet = Vec::with_capacity(64);
    // Header (12 bytes)
    packet.extend_from_slice(&[0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    // QNAME: \x0c_FC9F5ED42C8A \x04_tcp \x05local \x00
    packet.push(12);
    packet.extend_from_slice(b"_FC9F5ED42C8A");
    packet.push(4);
    packet.extend_from_slice(b"_tcp");
    packet.push(5);
    packet.extend_from_slice(b"local");
    packet.push(0);
    // QTYPE: PTR (12)
    packet.extend_from_slice(&[0x00, 0x0c]);
    // QCLASS: IN (1) | Unicast-response (0x8000) = 0x8001
    packet.extend_from_slice(&[0x80, 0x01]);

    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    let target = SocketAddr::V4(SocketAddrV4::new(gateway, 5353));
    socket.send_to(&packet, target).await?;

    let mut buf = [0u8; 4096];
    let (len, _) = tokio::time::timeout(Duration::from_millis(1500), socket.recv_from(&mut buf))
        .await
        .context("hotspot mDNS probe timed out")??;

    let response = &buf[..len];
    parse_mdns_response(gateway, response).context("failed to parse mDNS response")
}

fn parse_mdns_response(ip: Ipv4Addr, buf: &[u8]) -> Result<HotspotPeer> {
    if buf.len() < 12 {
        anyhow::bail!("DNS response too short");
    }
    let qdcount = u16::from_be_bytes([buf[4], buf[5]]) as usize;
    let ancount = u16::from_be_bytes([buf[6], buf[7]]) as usize;
    let arcount = u16::from_be_bytes([buf[10], buf[11]]) as usize;

    let mut pos = 12;

    for _ in 0..qdcount {
        pos = skip_name(buf, pos)?;
        if pos + 4 > buf.len() {
            anyhow::bail!("malformed question");
        }
        pos += 4;
    }

    let mut found_port = None;
    let mut found_n = None;

    for _ in 0..(ancount + arcount) {
        if pos >= buf.len() {
            break;
        }
        pos = skip_name(buf, pos)?;
        if pos + 10 > buf.len() {
            break;
        }
        let rrtype = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
        let rdlen = u16::from_be_bytes([buf[pos + 8], buf[pos + 9]]) as usize;
        pos += 10;
        if pos + rdlen > buf.len() {
            break;
        }
        let rdata = &buf[pos..pos + rdlen];
        pos += rdlen;

        // SRV Record (33): Priority(2) + Weight(2) + Port(2) + Target
        if rrtype == 33 && rdata.len() >= 6 {
            let port = u16::from_be_bytes([rdata[4], rdata[5]]);
            found_port = Some(port);
        }
        // TXT Record (16)
        if rrtype == 16 {
            let mut offset = 0;
            while offset < rdata.len() {
                let slen = rdata[offset] as usize;
                offset += 1;
                if offset + slen <= rdata.len() {
                    let entry = &rdata[offset..offset + slen];
                    offset += slen;
                    if let Ok(s) = std::str::from_utf8(entry) {
                        if s.starts_with("n=") {
                            found_n = Some(s[2..].to_string());
                        }
                    }
                } else {
                    break;
                }
            }
        }
    }

    let port = found_port.context("no SRV port in response")?;
    Ok(HotspotPeer { ip, port, raw_n: found_n })
}

fn skip_name(buf: &[u8], mut pos: usize) -> Result<usize> {
    while pos < buf.len() {
        let b = buf[pos];
        if b == 0 {
            return Ok(pos + 1);
        } else if (b & 0xC0) == 0xC0 {
            return Ok(pos + 2);
        } else {
            pos += (b as usize) + 1;
        }
    }
    anyhow::bail!("unexpected end of name")
}
