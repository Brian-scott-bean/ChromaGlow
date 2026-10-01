//! Minimal `log` backend: stderr lines (visible in the Xcode / devicectl
//! console), the latest warning for the in-app status row, and a bounded ring
//! of recent lines the app can copy for diagnostics.
//!
//! Verbosity: Debug for librespot's own crates and this one (that's where the
//! hand-off stages are logged), Info for everything else (hyper, websocket…).
//! librespot TRACE (which prints client/auth tokens) never runs.
//!
//! Sanitising — nothing that identifies the account or authenticates leaves
//! this logger:
//!  - "Authenticated as '<user>'" and "Login error for user <user>" are redacted;
//!  - the zeroconf server's debug line (method, path and ALL request params —
//!    including userName and the encrypted credential blob) is reduced to the
//!    action name;
//!  - any `access_token=` value is masked.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::Instant;

use log::{Level, LevelFilter, Log, Metadata, Record};

const RING_LINES: usize = 400;

static LAST_WARNING: Mutex<String> = Mutex::new(String::new());
static RING: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
static EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

struct ReceiverLogger;

static LOGGER: ReceiverLogger = ReceiverLogger;

pub fn install() {
    EPOCH.get_or_init(Instant::now);
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(LevelFilter::Debug);
    }
}

pub fn last_warning() -> String {
    LAST_WARNING.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Recent sanitised lines, oldest first, newline-separated.
pub fn recent_lines() -> String {
    let ring = RING.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = String::with_capacity(ring.iter().map(|l| l.len() + 1).sum());
    for line in ring.iter() {
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Note a line in the ring without a log level filter (receiver stages).
pub fn note(line: &str) {
    push(format!("{} {}", stamp(), line));
}

fn stamp() -> String {
    let t = EPOCH.get_or_init(Instant::now).elapsed();
    format!("{:>7.3}s", t.as_secs_f64())
}

fn push(line: String) {
    let mut ring = RING.lock().unwrap_or_else(|e| e.into_inner());
    if ring.len() == RING_LINES {
        ring.pop_front();
    }
    ring.push_back(line);
}

pub fn sanitize(target: &str, line: &str) -> String {
    // librespot_discovery::server: debug!("{:?} {:?} {:?}", method, path, params)
    if target.starts_with("librespot_discovery::server") && line.contains('{') {
        let head: String = line.split_whitespace().take(2).collect::<Vec<_>>().join(" ");
        let action = line
            .split("\"action\"")
            .nth(1)
            .and_then(|rest| rest.split('"').nth(1))
            .unwrap_or("?");
        return format!("zeroconf request {head} action={action} (params redacted)");
    }
    if let Some(start) = line.find("Authenticated as '") {
        return format!("{}Authenticated as '<redacted>' !", &line[..start]);
    }
    if let Some(start) = line.find("Login error for user ") {
        let tail = line.split(':').next_back().unwrap_or("");
        return format!("{}Login error for user <redacted>:{tail}", &line[..start]);
    }
    if let Some(start) = line.find("access_token=") {
        let value_start = start + "access_token=".len();
        let value_end = line[value_start..]
            .find(|c: char| c == '&' || c == ' ' || c == '"')
            .map_or(line.len(), |i| value_start + i);
        return format!("{}<redacted>{}", &line[..value_start], &line[value_end..]);
    }
    line.to_owned()
}

impl Log for ReceiverLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        let target = metadata.target();
        let ours = target.starts_with("librespot") || target.starts_with("chromaglow");
        metadata.level() <= if ours { Level::Debug } else { Level::Info }
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let target = record.target();
        let line = sanitize(target, &format!("{}", record.args()));
        eprintln!("[ChromaGlowSpotify] {} {}: {}", record.level(), target, line);
        push(format!("{} {:<5} {}: {}", stamp(), record.level(), target, line));
        if record.level() <= Level::Warn {
            *LAST_WARNING.lock().unwrap_or_else(|e| e.into_inner()) = line;
        }
    }

    fn flush(&self) {}
}

#[cfg(test)]
mod tests {
    use super::sanitize;

    #[test]
    fn username_is_redacted() {
        assert_eq!(sanitize("librespot_core::session", "Authenticated as 'someone123' !"),
                   "Authenticated as '<redacted>' !");
        assert_eq!(sanitize("x", "Country: \"GB\""), "Country: \"GB\"");
        assert_eq!(
            sanitize("librespot_discovery::server", "Login error for user \"someone\": MAC mismatch"),
            "Login error for user <redacted>: MAC mismatch"
        );
    }

    #[test]
    fn zeroconf_params_never_reach_the_log() {
        let raw = r#"POST "/" {"action": "addUser", "userName": "someone", "blob": "c2VjcmV0", "clientKey": "abc"}"#;
        let out = sanitize("librespot_discovery::server", raw);
        assert_eq!(out, r#"zeroconf request POST "/" action=addUser (params redacted)"#);
        assert!(!out.contains("someone") && !out.contains("c2VjcmV0") && !out.contains("abc"));
    }

    #[test]
    fn access_tokens_are_masked() {
        assert_eq!(sanitize("x", "GET wss://dealer:443/?access_token=SECRET&x=1"),
                   "GET wss://dealer:443/?access_token=<redacted>&x=1");
    }
}
