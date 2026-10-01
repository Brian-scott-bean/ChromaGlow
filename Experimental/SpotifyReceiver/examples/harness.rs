//! macOS host harness for the receiver's C ABI — drives exactly the functions
//! the iOS app calls. Usage:
//!   cargo run --example harness -- "<device name>" <seconds> [restarts] [desktop|native]
//! Prints a status line per second and PCM stats from the callback. With
//! `restarts` > 0 it stops and restarts the receiver that many times
//! (zombie-session check: `dns-sd -B _spotify-connect._tcp` must show one
//! record at a time and none after exit).

use std::ffi::{CStr, CString};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use chromaglow_spotify::{
    cg_spotify_copy_log, cg_spotify_librespot_revision, cg_spotify_set_persona, cg_spotify_start,
    cg_spotify_status, cg_spotify_stop, CGSpotifyStatus,
};

static FRAMES: AtomicU64 = AtomicU64::new(0);
static LAST_RMS_BITS: AtomicU32 = AtomicU32::new(0);
static LAST_GEN: AtomicU64 = AtomicU64::new(0);

extern "C" fn on_pcm(generation: u64, samples: *const f32, frames: u32, channels: u32, _rate: u32, _queued: u32) {
    let n = (frames * channels) as usize;
    // SAFETY: the library guarantees `frames * channels` readable samples.
    let s = unsafe { std::slice::from_raw_parts(samples, n) };
    let rms = (s.iter().map(|v| v * v).sum::<f32>() / n.max(1) as f32).sqrt();
    LAST_RMS_BITS.store(rms.to_bits(), Ordering::Relaxed);
    FRAMES.fetch_add(u64::from(frames), Ordering::Relaxed);
    LAST_GEN.store(generation, Ordering::Relaxed);
}

fn c_str(buf: &[std::os::raw::c_char]) -> String {
    unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
}

fn status() -> Option<CGSpotifyStatus> {
    let mut st: CGSpotifyStatus = unsafe { std::mem::zeroed() };
    unsafe { cg_spotify_status(&mut st) }.then_some(st)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args.get(1).cloned().unwrap_or_else(|| "ChromaGlow Sync (Mac harness)".into());
    let seconds: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(30);
    let restarts: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
    let desktop = args.get(4).map(|s| s != "native").unwrap_or(true);
    cg_spotify_set_persona(desktop);
    println!("persona: {}", if desktop { "desktop-speaker" } else { "native" });
    let rev = unsafe { CStr::from_ptr(cg_spotify_librespot_revision()) };
    println!("revision: {}", rev.to_string_lossy());

    let tmp = std::env::temp_dir().join("chromaglow-spotify-harness");
    let _ = std::fs::create_dir_all(&tmp);
    let c_name = CString::new(name.clone()).unwrap();
    let c_tmp = CString::new(tmp.to_string_lossy().into_owned()).unwrap();

    for round in 0..=restarts {
        let t0 = Instant::now();
        let gen = unsafe { cg_spotify_start(c_name.as_ptr(), c_tmp.as_ptr(), Some(on_pcm)) };
        println!("round {round}: started generation {gen} in {:?}", t0.elapsed());
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(seconds) {
            std::thread::sleep(Duration::from_secs(1));
            if let Some(st) = status() {
                println!(
                    "t={:>3}s gen={} state={} playback={} port={} vol={} frames={} chunks={} peak={:.3} rms={:.4} cb_gen={} track=\"{}\" artist=\"{}\" client=\"{}\" msg=\"{}\"",
                    start.elapsed().as_secs(),
                    st.generation,
                    st.state,
                    st.playback,
                    st.zeroconf_port,
                    st.volume,
                    st.frames_delivered,
                    st.chunks_delivered,
                    st.last_peak,
                    f32::from_bits(LAST_RMS_BITS.load(Ordering::Relaxed)),
                    LAST_GEN.load(Ordering::Relaxed),
                    c_str(&st.title),
                    c_str(&st.artist),
                    c_str(&st.remote_client),
                    c_str(&st.message),
                );
            }
        }
        let t1 = Instant::now();
        cg_spotify_stop();
        let st = status().unwrap();
        println!("round {round}: stopped in {:?}, final state={} frames={}", t1.elapsed(), st.state, st.frames_delivered);
    }
    let mut log = vec![0 as std::os::raw::c_char; 64 * 1024];
    let n = unsafe { cg_spotify_copy_log(log.as_mut_ptr(), log.len()) };
    println!("---- copied receiver log ({n} bytes) ----");
    println!("{}", unsafe { CStr::from_ptr(log.as_ptr()) }.to_string_lossy());
    let leftovers = std::fs::read_dir(&tmp).map(|d| d.count()).unwrap_or(0);
    println!("temp files left in {}: {leftovers}", tmp.display());
}
