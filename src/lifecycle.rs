//! AirDrop lifecycle monitor for macOS.
//!
//! Subscribes to Darwin notifications ("com.apple.sharingd.DiscoverableModeChanged",
//! "com.apple.sharingd.FinderAirDropChanged") using notify_register_file_descriptor.
//! Inspects sharingd's DiscoverableMode ("Off", "Contacts Only", "Everyone").
//! Ensures AirBridge Quick Share service only runs when AirDrop is active,
//! with ZERO continuous background task execution when AirDrop is turned off.

use std::os::fd::RawFd;
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
}

impl AirDropMode {
    pub fn is_active(&self) -> bool {
        matches!(self, AirDropMode::ContactsOnly | AirDropMode::Everyone)
    }
}

/// Reads the current DiscoverableMode preference from com.apple.sharingd.
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
                _ => return AirDropMode::Off,
            }
        }
    }
    AirDropMode::Off
}

/// Async watcher for macOS AirDrop state changes using Darwin notification file descriptors.
pub struct AirDropWatcher {
    async_fd: AsyncFd<RawFd>,
    token1: i32,
    token2: i32,
}

impl AirDropWatcher {
    pub fn new() -> Result<Self> {
        let mut fd: libc::c_int = -1;
        let mut token1: libc::c_int = 0;
        let mut token2: libc::c_int = 0;

        let name1 = std::ffi::CString::new("com.apple.sharingd.DiscoverableModeChanged")?;
        let status = unsafe {
            notify_register_file_descriptor(name1.as_ptr(), &mut fd, 0, &mut token1)
        };
        if status != 0 || fd < 0 {
            anyhow::bail!("failed to register DiscoverableModeChanged notification (status {status})");
        }

        let name2 = std::ffi::CString::new("com.apple.sharingd.FinderAirDropChanged")?;
        let status2 = unsafe {
            notify_register_file_descriptor(name2.as_ptr(), &mut fd, NOTIFY_REUSE, &mut token2)
        };
        if status2 != 0 {
            log::warn!("failed to register FinderAirDropChanged (status {status2})");
        }

        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL, 0);
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        let async_fd = AsyncFd::new(fd).context("AsyncFd creation for notify fd")?;
        Ok(Self { async_fd, token1, token2 })
    }

    /// Waits until an AirDrop state change occurs. Returns new AirDropMode.
    pub async fn wait_for_change(&mut self) -> Result<AirDropMode> {
        loop {
            let mut guard = self.async_fd.readable().await?;
            let mut buf = [0u8; 64];
            let raw_fd = *self.async_fd.get_ref();
            let n = unsafe { libc::read(raw_fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n > 0 {
                guard.clear_ready();
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
            if self.token1 != 0 {
                notify_cancel(self.token1);
            }
            if self.token2 != 0 {
                notify_cancel(self.token2);
            }
            libc::close(*self.async_fd.get_ref());
        }
    }
}
