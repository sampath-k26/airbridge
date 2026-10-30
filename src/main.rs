//! AirBridge: Native AirDrop ↔ Quick Share bridge for macOS and Android.
//!
//! Features:
//! - Direct sharing between macOS Finder (AirDrop) and Android (Quick Share).
//! - Zero app needed on the phone; uses native Quick Share.
//! - Simultaneous support for local Wi-Fi and Mobile Hotspot tethering.
//! - On-demand AirDrop lifecycle: active only when AirDrop is enabled; zero background tasks when disabled.

mod airdrop;
mod archive;
mod ble;
mod bonjour;
mod discovery;
mod hotspot;
mod lifecycle;
mod names;
mod qr;
mod tls;
mod update;

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use rqs_lib::channel::{ChannelAction, ChannelDirection, ChannelMessage, TransferType};
use rqs_lib::{DeviceType, OutboundPayload, SendInfo, State, Visibility, RQS};
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;

const AIRDROP_FLAGS: u32 = 0x88;
const SEND_TIMEOUT: Duration = Duration::from_secs(600);

const USAGE: &str = "\
airbridge: seamless AirDrop ↔ Quick Share bridge for macOS and Android

USAGE: airbridge [--auto-accept] [--download-dir <path>] [--always-on]
       airbridge start       start the background service
       airbridge stop        stop the background service and running bridge
       airbridge status      show bridge running state and AirDrop mode
       airbridge doctor      check setup, AirDrop status, Wi-Fi, Hotspot, and reach
       airbridge qr [<file>...]
                             show a QR code to scan on a phone that doesn't show up in AirDrop;
                             with files, send them as soon as the phone has scanned it

  --auto-accept          accept incoming Quick Share files without asking
  --download-dir <path>  where incoming files go (default: ~/Downloads)
  --always-on            run continuously instead of stopping when AirDrop is turned off

By default, AirBridge operates on-demand with macOS AirDrop. When AirDrop is turned OFF
or Finder AirDrop is closed, AirBridge cleanly deactivates all background tasks and stops.";

struct Options {
    start: bool,
    stop: bool,
    status: bool,
    doctor: bool,
    qr: bool,
    files: Vec<PathBuf>,
    auto_accept: bool,
    download_dir: Option<PathBuf>,
    always_on: bool,
}

fn parse_args() -> Result<Options> {
    let mut o = Options {
        start: false,
        stop: false,
        status: false,
        doctor: false,
        qr: false,
        files: Vec::new(),
        auto_accept: false,
        download_dir: None,
        always_on: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "start" => o.start = true,
            "stop" => o.stop = true,
            "status" => o.status = true,
            "doctor" => o.doctor = true,
            "qr" => o.qr = true,
            "--auto-accept" => o.auto_accept = true,
            "--always-on" => o.always_on = true,
            "--download-dir" => o.download_dir = Some(args.next().context("--download-dir needs a path")?.into()),
            "-V" | "--version" => {
                println!("airbridge {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            file if o.qr && !file.starts_with('-') => o.files.push(file.into()),
            other => bail!("unknown argument {other:?}\n\n{USAGE}"),
        }
    }
    Ok(o)
}

fn run_stop() -> Result<()> {
    println!("Stopping AirBridge...");
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let plist = format!("{home}/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist");
    if std::path::Path::new(&plist).exists() {
        let _ = std::process::Command::new("/bin/launchctl")
            .args(["unload", &plist])
            .output();
    }

    // Kill any running airbridge processes except this one
    let my_pid = std::process::id();
    if let Ok(output) = std::process::Command::new("pgrep").args(["-x", "airbridge"]).output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Ok(pid) = line.trim().parse::<u32>() {
                if pid != my_pid {
                    unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
                }
            }
        }
    }

    println!("\x1b[1;32m✔ AirBridge service and background processes have been stopped.\x1b[0m");
    Ok(())
}

fn run_start() -> Result<()> {
    println!("Starting AirBridge...");
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let plist = format!("{home}/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist");
    if std::path::Path::new(&plist).exists() {
        let _ = std::process::Command::new("/bin/launchctl").args(["unload", &plist]).output();
        let status = std::process::Command::new("/bin/launchctl")
            .args(["load", &plist])
            .status();
        if let Ok(s) = status {
            if s.success() {
                println!("\x1b[1;32m✔ AirBridge background service loaded and activated!\x1b[0m");
                return Ok(());
            }
        }
    }
    println!("No LaunchAgent plist found at ~/Library/LaunchAgents/com.sunkaramahesh.airbridge.plist.");
    println!("Run 'install.sh' to register the LaunchAgent service, or run 'airbridge' directly.");
    Ok(())
}

fn run_status() -> Result<()> {
    let mode = lifecycle::current_mode();
    let finder_active = lifecycle::is_finder_airdrop_active();
    let awdl = bonjour::awdl_address().is_some();

    let my_pid = std::process::id();
    let mut running_pids = Vec::new();
    if let Ok(output) = std::process::Command::new("pgrep").args(["-x", "airbridge"]).output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Ok(pid) = line.trim().parse::<u32>() {
                if pid != my_pid {
                    running_pids.push(pid);
                }
            }
        }
    }

    println!("\n=== AirBridge Status ===");
    if !running_pids.is_empty() {
        println!("Process Status        : RUNNING (PID: {})", running_pids.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(", "));
    } else {
        println!("Process Status        : STOPPED");
    }
    println!("macOS AirDrop Mode    : {:?}", mode);
    println!("Finder AirDrop Active : {}", if finder_active { "Yes (Window Open)" } else { "No" });
    println!("AWDL (awdl0) State    : {}", if awdl { "ACTIVE (OK)" } else { "INACTIVE" });
    println!("========================\n");
    Ok(())
}

struct Peer {
    name: String,
    addr: Arc<Mutex<String>>,
    _ad: bonjour::Advertisement,
    server: JoinHandle<()>,
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.server.abort();
    }
}

/// Active bridge runtime state when AirDrop is enabled.
struct ActiveBridge {
    rqs: RQS,
    send_tx: mpsc::Sender<SendInfo>,
    disc: mpsc::Receiver<discovery::Event>,
    disc_handle: discovery::DiscoveryHandle,
    peers: HashMap<std::net::Ipv4Addr, Peer>,
    inbound_handle: JoinHandle<()>,
}

impl ActiveBridge {
    pub async fn stop(mut self) {
        self.peers.clear();
        self.inbound_handle.abort();
        self.disc_handle.abort();
        tokio::time::sleep(Duration::from_millis(100)).await;
        self.rqs.stop().await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let opts = parse_args()?;
    if opts.stop {
        return run_stop();
    }
    if opts.start {
        return run_start();
    }
    if opts.status {
        return run_status();
    }

    if std::env::var_os("RUST_LOG").is_none() {
        let mdns = if opts.qr { "off" } else { "error" };
        std::env::set_var("RUST_LOG", format!("info,rqs_lib=warn,mdns_sd={mdns}"));
    }
    tracing_subscriber::fmt::init();

    let home = PathBuf::from(std::env::var_os("HOME").context("HOME not set")?);
    let support = home.join("Library/Application Support/airbridge");
    let names_path = support.join("names.tsv");
    let qr = qr::load(&support)?;

    if opts.qr {
        return show_qr(qr, opts.files).await;
    }
    if opts.doctor {
        return run_doctor(names::Names::load(names_path), qr).await;
    }

    let tls = tls::acceptor(&support)?;
    let spool = home.join("Library/Caches/airbridge");

    if bonjour::awdl_address().is_none() {
        log::warn!("awdl0 interface is currently inactive; Wi-Fi may be off");
    }

    let mut names = names::Names::load(names_path);
    let (learn_tx, mut learned) = mpsc::channel(8);
    let (mut term, mut int) = (signal(SignalKind::terminate())?, signal(SignalKind::interrupt())?);

    let mut watcher = lifecycle::AirDropWatcher::new()?;
    let mut current_airdrop_mode = lifecycle::current_mode();
    let should_run = opts.always_on || current_airdrop_mode.is_active();

    log::info!(
        "AirBridge initialized (AirDrop mode: {:?}, on-demand: {})",
        current_airdrop_mode,
        !opts.always_on
    );

    let mut active: Option<ActiveBridge> = if should_run {
        Some(start_bridge(&opts, &qr, learn_tx.clone()).await?)
    } else {
        log::info!("AirDrop is currently OFF. AirBridge is waiting for AirDrop to activate (open Finder AirDrop or enable in Control Center)...");
        None
    };

    loop {
        tokio::select! {
            _ = term.recv() => break,
            _ = int.recv() => break,

            // Watch for changes in macOS AirDrop state
            Ok(new_mode) = watcher.wait_for_change(), if !opts.always_on => {
                if new_mode != current_airdrop_mode {
                    log::info!("macOS AirDrop state changed: {:?} -> {:?}", current_airdrop_mode, new_mode);
                    current_airdrop_mode = new_mode;

                    if current_airdrop_mode.is_active() && active.is_none() {
                        log::info!("AirDrop turned ON / Finder AirDrop opened -> Activating Quick Share bridge");
                        match start_bridge(&opts, &qr, learn_tx.clone()).await {
                            Ok(b) => active = Some(b),
                            Err(e) => log::error!("Failed to activate bridge: {e:#}"),
                        }
                    } else if !current_airdrop_mode.is_active() && active.is_some() {
                        log::info!("AirDrop turned OFF or stopped -> Deactivating bridge");
                        if let Some(b) = active.take() {
                            b.stop().await;
                        }
                        log::info!("AirDrop stopped. AirBridge stopping cleanly.");
                        break;
                    }
                }
            }

            // Inbound discovery events from active bridge
            Some(ev) = async {
                match active.as_mut() {
                    Some(b) => b.disc.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                if let Some(b) = active.as_mut() {
                    on_discovery(ev, &mut names, &mut b.peers, &tls, &spool, &b.send_tx, &b.rqs);
                }
            }

            // Learned phone names from incoming transfers
            Some((ip, name)) = learned.recv() => {
                if names.learn(ip, &name) {
                    if let Some(b) = active.as_mut() {
                        if let Some(addr) = b.peers.get(&ip).map(|p| p.addr.lock().unwrap().clone()) {
                            let ev = discovery::Event::Found { ip, name: None, addr, qr: false };
                            on_discovery(ev, &mut names, &mut b.peers, &tls, &spool, &b.send_tx, &b.rqs);
                        }
                    }
                }
            }
        }
    }

    log::info!("AirBridge stopping");
    if let Some(b) = active.take() {
        b.stop().await;
    }
    Ok(())
}

async fn start_bridge(
    opts: &Options,
    qr: &qr::Key,
    learn_tx: mpsc::Sender<(std::net::Ipv4Addr, String)>,
) -> Result<ActiveBridge> {
    let mut rqs = RQS::new(Visibility::Visible, None, opts.download_dir.clone());
    let (send_tx, _) = rqs.run().await?;
    let (disc, disc_handle) = discovery::start(qr.clone_key())?;
    let inbound_handle = tokio::spawn(inbound(rqs.message_sender.clone(), opts.auto_accept, learn_tx));
    log::info!("Quick Share bridge active: scanning local Wi-Fi & mobile hotspot gateway...");
    Ok(ActiveBridge {
        rqs,
        send_tx,
        disc,
        disc_handle,
        peers: HashMap::new(),
        inbound_handle,
    })
}

fn on_discovery(
    ev: discovery::Event,
    names: &mut names::Names,
    peers: &mut HashMap<std::net::Ipv4Addr, Peer>,
    tls: &tokio_rustls::TlsAcceptor,
    spool: &std::path::Path,
    send_tx: &mpsc::Sender<SendInfo>,
    rqs: &RQS,
) {
    let (ip, name, addr) = match ev {
        discovery::Event::DeskProximityFound { endpoint_id, name, rssi } => {
            let phone_name = name.unwrap_or_else(|| format!("Nearby Phone ({endpoint_id})"));
            log::info!("Mode 3 [Desk Proximity]: {phone_name} discovered via BLE (RSSI {rssi} dBm)");
            return;
        }
        discovery::Event::DeskProximityLost { endpoint_id } => {
            log::debug!("Mode 3 [Desk Proximity]: Device {endpoint_id} left desk range");
            return;
        }
        discovery::Event::Lost { ip } => {
            if let Some(p) = peers.remove(&ip) {
                log::info!("{} ({ip}) left reach", p.name);
            }
            return;
        }
        discovery::Event::Found { ip, name, addr, .. } => (ip, name, addr),
    };
    let name = match name {
        Some(n) => {
            names.learn(ip, &n);
            n
        }
        None => names.get(&ip).map_or_else(|| format!("Android phone {}", ip.octets()[3]), str::to_string),
    };
    if let Some(p) = peers.get(&ip) {
        if p.name == name {
            *p.addr.lock().unwrap() = addr;
            return;
        }
        peers.remove(&ip);
    }
    match add_peer(ip, &name, &addr, tls, spool, send_tx, rqs) {
        Ok(p) => {
            log::info!("{name} ({ip}) is now available in Finder AirDrop");
            peers.insert(ip, p);
        }
        Err(e) => log::warn!("could not add {name} to AirDrop: {e:#}"),
    }
}

fn add_peer(
    ip: std::net::Ipv4Addr,
    name: &str,
    addr: &str,
    tls: &tokio_rustls::TlsAcceptor,
    spool: &std::path::Path,
    send_tx: &mpsc::Sender<SendInfo>,
    rqs: &RQS,
) -> Result<Peer> {
    let addr = Arc::new(Mutex::new(addr.to_string()));
    let forward: airdrop::Forward = {
        let (addr, name, send_tx, msgs) = (addr.clone(), name.to_string(), send_tx.clone(), rqs.message_sender.clone());
        Arc::new(move |files| {
            let target = addr.lock().unwrap().clone();
            Box::pin(send_files(send_tx.clone(), msgs.clone(), name.clone(), target, files))
        })
    };
    let (ad, server) = advertise_peer(&ip.to_string(), name, forward, tls, spool)?;
    Ok(Peer { name: name.to_string(), addr, _ad: ad, server })
}

fn advertise_peer(
    key: &str,
    name: &str,
    forward: airdrop::Forward,
    tls: &tokio_rustls::TlsAcceptor,
    spool: &std::path::Path,
) -> Result<(bonjour::Advertisement, JoinHandle<()>)> {
    let mut host = [0u8; 256];
    unsafe { libc::gethostname(host.as_mut_ptr().cast(), host.len()) };
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (key, name, host).hash(&mut h);
    let tag = format!("{:012x}", h.finish() & 0xffff_ffff_ffff);
    let listener = airdrop::bind()?;
    let port = listener.local_addr()?.port();
    let receiver = airdrop::Receiver {
        name: format!("AirBridge - {name}"),
        model: "Android".into(),
        spool: spool.join(&tag),
        forward,
    };
    let ad = bonjour::advertise(&tag, &format!("airbridge-{tag}"), port, AIRDROP_FLAGS)?;
    log::debug!("{name}: registered AirDrop service {tag} on port {port}");
    Ok((ad, tokio::spawn(airdrop::serve(listener, tls.clone(), Arc::new(receiver)))))
}

async fn send_files(
    send_tx: mpsc::Sender<SendInfo>,
    msgs: broadcast::Sender<ChannelMessage>,
    name: String,
    addr: String,
    files: Vec<PathBuf>,
) -> Result<()> {
    let mut rx = msgs.subscribe();
    let files = files.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    send_tx
        .send(SendInfo {
            id: addr.clone(),
            name: name.clone(),
            addr: addr.clone(),
            ob: OutboundPayload::Files(files),
        })
        .await?;
    let wait = async {
        loop {
            let m = match rx.recv().await {
                Ok(m) => m,
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(e) => return Err(e.into()),
            };
            if m.id != addr || m.direction != ChannelDirection::LibToFront {
                continue;
            }
            match m.state {
                Some(State::Finished) => return Ok(()),
                Some(State::Rejected) => bail!("declined on {name}"),
                Some(State::Cancelled) => bail!("cancelled on {name}"),
                Some(State::Disconnected) => bail!("{name} disconnected"),
                _ => {}
            }
        }
    };
    tokio::time::timeout(SEND_TIMEOUT, wait).await.context("no response from phone")?
}

async fn inbound(
    msgs: broadcast::Sender<ChannelMessage>,
    auto_accept: bool,
    learn: mpsc::Sender<(std::net::Ipv4Addr, String)>,
) {
    let mut rx = msgs.subscribe();
    let mut asked = std::collections::HashSet::new();
    loop {
        let m = match rx.recv().await {
            Ok(m) => m,
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => return,
        };
        if m.direction != ChannelDirection::LibToFront || m.rtype != Some(TransferType::Inbound) {
            continue;
        }
        let meta = m.meta.clone().unwrap_or_default();
        let from = meta.source.as_ref().map_or("A device".to_string(), |s| s.name.clone());
        let files = meta.files.clone().unwrap_or_default();
        if let (Some(src), Some(Ok(ip))) = (&meta.source, m.id.split(':').next().map(str::parse)) {
            if src.device_type != DeviceType::Laptop {
                let _ = learn.try_send((ip, src.name.clone()));
            }
        }
        match m.state {
            Some(State::WaitingForUserConsent) if asked.insert(m.id.clone()) => {
                let msgs = msgs.clone();
                tokio::spawn(async move {
                    let pin = meta.pin_code.unwrap_or_default();
                    let ok = auto_accept
                        || ask(&format!("{from} wants to send you:\n\n{}\n\nPIN: {pin}", files.join("\n"))).await;
                    let action = if ok { ChannelAction::AcceptTransfer } else { ChannelAction::RejectTransfer };
                    let _ = msgs.send(ChannelMessage {
                        id: m.id,
                        direction: ChannelDirection::FrontToLib,
                        action: Some(action),
                        ..Default::default()
                    });
                });
            }
            Some(State::Finished) => {
                asked.remove(&m.id);
                notify("AirBridge", &format!("Received {} file(s) from {from}", files.len())).await;
            }
            Some(State::Rejected | State::Cancelled | State::Disconnected) => {
                asked.remove(&m.id);
            }
            _ => {}
        }
    }
}

async fn ask(text: &str) -> bool {
    let out = tokio::process::Command::new("/usr/bin/osascript")
        .args([
            "-e", "on run argv",
            "-e", r#"display dialog (item 1 of argv) with title "AirBridge" buttons {"Decline", "Accept"} default button "Accept" giving up after 60"#,
            "-e", "end run",
            text,
        ])
        .output()
        .await;
    matches!(out, Ok(o) if String::from_utf8_lossy(&o.stdout).contains("button returned:Accept"))
}

async fn notify(title: &str, text: &str) {
    let _ = tokio::process::Command::new("/usr/bin/osascript")
        .args(["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", title, text])
        .status()
        .await;
}

async fn show_qr(qr: qr::Key, _files: Vec<PathBuf>) -> Result<()> {
    println!("\nScan this QR code with the phone camera to reveal Quick Share name:\n");
    let code = qrcode::QrCode::new(qr.url())?;
    println!("{}", code.render::<qrcode::render::unicode::Dense1x2>().build());
    println!("URL: {}\n", qr.url());
    Ok(())
}

async fn run_doctor(_names: names::Names, _qr: qr::Key) -> Result<()> {
    let mode = lifecycle::current_mode();
    let finder_active = lifecycle::is_finder_airdrop_active();
    let awdl = bonjour::awdl_address().is_some();
    let hotspot = hotspot::get_default_gateway();

    println!("\n=== AirBridge Diagnostics ===");
    println!("macOS AirDrop Status  : {:?}", mode);
    println!("Finder AirDrop Active : {}", if finder_active { "Yes (Window Open)" } else { "No" });
    println!("AWDL Interface (awdl0): {}", if awdl { "ACTIVE (OK)" } else { "INACTIVE (Wi-Fi off?)" });
    println!("Mode 1 (Wi-Fi LAN)    : Enabled (mDNS _FC9F5ED42C8A._tcp.local)");
    if let Some((gw, iface)) = hotspot {
        let is_hs = hotspot::is_likely_hotspot(gw);
        println!("Mode 2 (Hotspot AP)   : Gateway {gw} on {iface} {}", if is_hs { "[Mobile Hotspot DETECTED]" } else { "[Standard LAN]" });
    } else {
        println!("Mode 2 (Hotspot AP)   : No Gateway Detected");
    }
    println!("Mode 3 (Desk Proximity: BLE Scanner Active (UUID 0xFEF3, threshold: {} dBm)", ble::DEFAULT_DESK_RSSI_THRESHOLD);
    println!("Known Devices         : saved in names.tsv");
    println!("=============================\n");
    Ok(())
}
