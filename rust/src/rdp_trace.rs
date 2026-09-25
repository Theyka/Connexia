//! Opt-in hex tracing for the Standard RDP Security (RC4) handshake.
//!
//! This exists to debug legacy servers that reject our Client Info with
//! `ERRINFO_DECRYPT_FAILED`. It is disabled unless the `CONNEXIA_RDP_TRACE`
//! environment variable is set, and appends to
//! `%TEMP%\connexia-rdp-trace.log` (or the path in
//! `CONNEXIA_RDP_TRACE_FILE`).

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Instant;

fn enabled() -> bool {
    std::env::var_os("CONNEXIA_RDP_TRACE").is_some()
}

fn elapsed_ms() -> u128 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis()
}

fn path() -> &'static PathBuf {
    static PATH: OnceLock<PathBuf> = OnceLock::new();
    PATH.get_or_init(|| {
        std::env::var_os("CONNEXIA_RDP_TRACE_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("connexia-rdp-trace.log"))
    })
}

pub fn line(message: &str) {
    if !enabled() {
        return;
    }

    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path())
    {
        let _ = writeln!(file, "[{:>6}ms] {message}", elapsed_ms());
    }
}

/// Always-on, low-volume clipboard diagnostics. Written to
/// `%TEMP%\connexia-clipboard.log` so clipboard failures can be diagnosed
/// without enabling full protocol tracing.
pub fn clipboard(message: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(std::env::temp_dir().join("connexia-clipboard.log"))
    {
        let _ = writeln!(file, "[{:>6}ms] {message}", elapsed_ms());
    }
}

pub fn hex(label: &str, bytes: &[u8]) {
    if !enabled() {
        return;
    }

    let encoded: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    line(&format!("{label} ({} bytes): {encoded}", bytes.len()));
}
