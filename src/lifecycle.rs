//! AirDrop lifecycle monitor for macOS.
//!
//! Subscribes to Darwin notifications ("com.apple.sharingd.DiscoverableModeChanged",
//! "com.apple.sharingd.FinderAirDropChanged", "com.apple.sharingd.AirDropChanged",
//! "com.apple.sharingd.AirDropStatusChanged", "com.apple.sharingd.AirDropLinkStateChanged")
//! using notify_register_file_descriptor.
//! Inspects sharingd's DiscoverableMode ("Off", "Contacts Only", "Everyone")
//! as well as active Finder AirDrop windows.
//! Ensures AirBridge Quick Share service only runs when AirDrop is active,
//! with ZERO continuous background task execution when AirDrop is turned off or closed.

use std::os::fd::RawFd;
use std::time::Duration;
use anyhow::{Context, Result};
use tokio::io::unix::AsyncFd;

const NOTIFY_REUSE: libc::c_int = 0x00000001;

extern "C" {
    fn notify_register_file_descriptor(
        name: *const libc::c_char,
        notify_fd: *mut libc::c_int,
        flags: libc::c_int,
        out_token: *mut libc::c_int,
    ) -> u32;
    fn notify_cancel(token: libc::c_int) -> u32;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AirDropMode {
    Off,
    ContactsOnly,
    Everyone,
    FinderActive,
}

impl AirDropMode {
    pub fn is_active(&self) -> bool {
        matches!(self, AirDropMode::ContactsOnly | AirDropMode::Everyone | AirDropMode::FinderActive)
    }
}

/// Checks if Finder currently has an AirDrop window open.
pub fn is_finder_airdrop_active() -> bool {
    let script = r#"
        tell application "Finder"
            try
                if (count of windows) > 0 then
                    set winNames to name of every window
                    if winNames contains "AirDrop" then
                        return "true"
                    end if
                end if
            end try
            return "false"
        end tell
    "#;
    if let Ok(output) = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", script])
        .output()
    {
        if output.status.success() {
            let res = String::from_utf8_lossy(&output.stdout).trim().to_string();
            return res == "true";
        }
    }
    false
}

/// Reads the current DiscoverableMode preference from com.apple.sharingd
/// and checks if Finder has an AirDrop window open.
pub fn current_mode() -> AirDropMode {
    if let Ok(output) = std::process::Command::new("/usr/bin/defaults")
        .args(["read", "com.apple.sharingd", "DiscoverableMode"])
        .output()
    {
        if output.status.success() {
            let mode = String::from_utf8_lossy(&output.stdout).trim().to_string();
            match mode.as_str() {
                "Everyone" => return AirDropMode::Everyone,
                "Contacts Only" => return AirDropMode::ContactsOnly,
                _ => {}
            }
        }
    }

    if is_finder_airdrop_active() {
        return AirDropMode::FinderActive;
    }

    AirDropMode::Off
}

/// Async watcher for macOS AirDrop state changes using Darwin notification file descriptors.
pub struct AirDropWatcher {
    async_fd: AsyncFd<RawFd>,
    tokens: Vec<i32>,
}

impl AirDropWatcher {
    pub fn new() -> Result<Self> {
        let mut fd: libc::c_int = -1;
        let mut tokens = Vec::new();

        let notifs = [
            "com.apple.sharingd.DiscoverableModeChanged",
            "com.apple.sharingd.FinderAirDropChanged",
            "com.apple.sharingd.AirDropChanged",
            "com.apple.sharingd.AirDropStatusChanged",
            "com.apple.sharingd.AirDropLinkStateChanged",
        ];

        for (i, name_str) in notifs.iter().enumerate() {
            let cname = std::ffi::CString::new(*name_str)?;
            let mut tok: libc::c_int = 0;
            let flags = if i == 0 { 0 } else { NOTIFY_REUSE };
            let status = unsafe {
                notify_register_file_descriptor(cname.as_ptr(), &mut fd, flags, &mut tok)
            };
            if status == 0 && tok != 0 {
                tokens.push(tok);
            } else if i == 0 {
                anyhow::bail!("failed to register {name_str} notification (status {status})");
            } else {
                log::debug!("optional notification {name_str} not registered (status {status})");
            }
        }

        if fd < 0 {
            anyhow::bail!("invalid notify file descriptor");
        }

        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL, 0);
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        #[allow(deprecated)]
        let async_fd = AsyncFd::new(fd).context("AsyncFd creation for notify fd")?;
        Ok(Self { async_fd, tokens })
    }

    /// Waits until an AirDrop state change occurs. Returns new AirDropMode.
    pub async fn wait_for_change(&mut self) -> Result<AirDropMode> {
        loop {
            let mut guard = self.async_fd.readable().await?;
            let mut buf = [0u8; 128];
            let raw_fd = *self.async_fd.get_ref();
            let n = unsafe { libc::read(raw_fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n > 0 {
                guard.clear_ready();
                // Allow a brief moment for defaults / Finder window state to settle
                tokio::time::sleep(Duration::from_millis(50)).await;
                return Ok(current_mode());
            } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock {
                guard.clear_ready();
                continue;
            } else {
                guard.clear_ready();
                return Ok(current_mode());
            }
        }
    }
}

impl Drop for AirDropWatcher {
    fn drop(&mut self) {
        unsafe {
            for tok in &self.tokens {
                if *tok != 0 {
                    notify_cancel(*tok);
                }
            }
            libc::close(*self.async_fd.get_ref());
        }
    }
}
