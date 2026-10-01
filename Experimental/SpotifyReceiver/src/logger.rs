//! Minimal `log` backend: stderr lines (visible in the Xcode / devicectl
//! console) plus the latest warning for the in-app diagnostics row.
//!
//! Capped at Info so librespot's TRACE output (which prints client tokens)
//! never runs, and account identifiers are redacted from the one Info line
//! that carries them.

use std::sync::Mutex;

use log::{Level, LevelFilter, Log, Metadata, Record};

static LAST_WARNING: Mutex<String> = Mutex::new(String::new());

struct ReceiverLogger;

static LOGGER: ReceiverLogger = ReceiverLogger;

pub fn install() {
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(LevelFilter::Info);
    }
}

pub fn last_warning() -> String {
    LAST_WARNING.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn redact(line: &str) -> String {
    // librespot: "Authenticated as '<username>' !"
    if let Some(start) = line.find("Authenticated as '") {
        let head = &line[..start];
        return format!("{head}Authenticated as '<redacted>' !");
    }
    line.to_owned()
}

impl Log for ReceiverLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= Level::Info
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = redact(&format!("{}", record.args()));
        eprintln!("[ChromaGlowSpotify] {} {}: {}", record.level(), record.target(), line);
        if record.level() <= Level::Warn {
            *LAST_WARNING.lock().unwrap_or_else(|e| e.into_inner()) = line;
        }
    }

    fn flush(&self) {}
}

#[cfg(test)]
mod tests {
    use super::redact;

    #[test]
    fn username_is_redacted() {
        assert_eq!(redact("Authenticated as 'someone123' !"), "Authenticated as '<redacted>' !");
        assert_eq!(redact("Country: \"GB\""), "Country: \"GB\"");
    }
}
