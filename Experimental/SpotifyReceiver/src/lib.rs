//! ChromaGlow local Spotify Connect receiver — LOCAL-ONLY EXPERIMENT.
//!
//! A deliberately tiny C ABI (include/chromaglow_spotify.h) over a pinned
//! librespot: start / stop / poll status / pull playback PCM, plus one PCM
//! callback. Nothing librespot-shaped crosses the boundary.
//!
//! Credentials arrive only through Spotify Connect's zeroconf hand-off (the
//! Spotify app encrypts a reusable blob to this device's DH key). No username,
//! password, token or cache directory is ever configured, so nothing about the
//! account is persisted. librespot buffers the *encrypted* compressed stream in
//! an unlinked-on-drop temp file inside `temp_dir`; the Swift side purges that
//! directory on every start and stop. Decoded PCM never touches storage.

mod logger;
mod ring;
mod sink;
mod state;

use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::authentication::Credentials;
use librespot_core::config::{DeviceType, SessionConfig};
use librespot_core::Session;
use librespot_discovery::Discovery;
use librespot_metadata::audio::UniqueFields;
use librespot_playback::config::PlayerConfig;
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig, NoOpVolume};
use librespot_playback::player::{Player, PlayerEvent, PlayerEventChannel};
use sha1::{Digest, Sha1};
use tokio::sync::oneshot;

pub use state::{CGSpotifyStatus, PcmCallback, PlaybackState, ReceiverState};

use sink::{ChromaSink, PlaybackPlumbing};
use state::{copy_c_string, Shared};

/// The exact upstream revision this library is built from.
pub const LIBRESPOT_REVISION: &str = "939dc5ee9d833e1980f9495241219d9d4868a061";
static REVISION_C: &[u8] = b"librespot dev@939dc5ee9d833e1980f9495241219d9d4868a061\0";

const SHUTDOWN_STEP_TIMEOUT: Duration = Duration::from_secs(2);
/// Login + Connect setup normally takes 1–3 s; a hang becomes an explicit error.
const SESSION_SETUP_TIMEOUT: Duration = Duration::from_secs(40);
const RECONNECT_WINDOW: Duration = Duration::from_secs(60);
const RECONNECT_LIMIT: usize = 4;

struct Runner {
    handle: JoinHandle<()>,
    shutdown: oneshot::Sender<()>,
}

static NEXT_GENERATION: AtomicU64 = AtomicU64::new(0);
static RUNNER: Mutex<Option<Runner>> = Mutex::new(None);
static CURRENT: Mutex<Option<Arc<Shared>>> = Mutex::new(None);
static PLUMBING: OnceLock<Arc<PlaybackPlumbing>> = OnceLock::new();
/// true = log in as librespot's desktop-Linux speaker; false = the build
/// target's own identity (iPhone on iOS). Read at each start.
static PERSONA_DESKTOP: AtomicBool = AtomicBool::new(true);

fn plumbing() -> &'static Arc<PlaybackPlumbing> {
    PLUMBING.get_or_init(|| Arc::new(PlaybackPlumbing::new()))
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Stable per-name, per-persona device id so Spotify doesn't accumulate ghost
/// devices or mix up the two identities.
fn device_id_for(name: &str, desktop_persona: bool) -> String {
    let mut h = Sha1::new();
    h.update(b"chromaglow-local-spotify-experiment:");
    h.update(name.as_bytes());
    if desktop_persona {
        h.update(b":desktop-linux");
    }
    hex::encode(h.finalize())
}

fn pick_free_port() -> u16 {
    std::net::TcpListener::bind(("0.0.0.0", 0))
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .unwrap_or(0)
}

/// Request shutdown of the running receiver (if any) and wait for it. The
/// current generation's PCM gate closes before anything else happens.
fn stop_and_join() {
    if let Some(cur) = lock(&CURRENT).as_ref() {
        cur.stop.store(true, Ordering::Release);
    }
    let runner = lock(&RUNNER).take();
    if let Some(runner) = runner {
        let _ = runner.shutdown.send(());
        let _ = runner.handle.join();
    }
    let p = plumbing();
    p.enabled.store(false, Ordering::Release);
    p.ring.request_clear();
}

// MARK: - C ABI

/// Start the receiver. Stops (and joins) any previous one first, so two
/// receivers never advertise at once. Returns the new generation (> 0), or 0
/// on invalid arguments. Blocking only for the duration of a previous stop.
///
/// # Safety
/// `device_name` and `temp_dir` must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn cg_spotify_start(
    device_name: *const c_char,
    temp_dir: *const c_char,
    pcm_callback: Option<PcmCallback>,
) -> u64 {
    if device_name.is_null() || temp_dir.is_null() {
        return 0;
    }
    let name = match CStr::from_ptr(device_name).to_str() {
        Ok(s) if !s.trim().is_empty() => s.to_owned(),
        _ => return 0,
    };
    let tmp = match CStr::from_ptr(temp_dir).to_str() {
        Ok(s) if !s.is_empty() => PathBuf::from(s),
        _ => return 0,
    };
    catch_unwind(AssertUnwindSafe(|| {
        logger::install();
        stop_and_join();

        let generation = NEXT_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        let shared = Arc::new(Shared::new(generation, pcm_callback));
        *lock(&CURRENT) = Some(shared.clone());

        let (tx, rx) = oneshot::channel();
        let spawned = std::thread::Builder::new()
            .name("cg-spotify-rx".into())
            .spawn(move || runner_main(name, tmp, shared, rx));
        match spawned {
            Ok(handle) => {
                *lock(&RUNNER) = Some(Runner { handle, shutdown: tx });
                generation
            }
            Err(_) => 0,
        }
    }))
    .unwrap_or(0)
}

/// Stop the receiver and wait for librespot to shut down (≈ ≤ 6 s worst case;
/// call off the main thread). PCM callbacks stop before this blocks.
#[no_mangle]
pub extern "C" fn cg_spotify_stop() {
    let _ = catch_unwind(stop_and_join);
}

/// Copy the current (or last) receiver's status. Returns false if no receiver
/// has run yet in this process.
///
/// # Safety
/// `out` must point to a writable `CGSpotifyStatus`.
#[no_mangle]
pub unsafe extern "C" fn cg_spotify_status(out: *mut CGSpotifyStatus) -> bool {
    if out.is_null() {
        return false;
    }
    let out = &mut *out;
    catch_unwind(AssertUnwindSafe(|| {
        let guard = lock(&CURRENT);
        let Some(shared) = guard.as_ref() else { return false };
        shared.fill_status(out, plumbing().ring.len_frames() as u32);
        if out.message[0] == 0 {
            copy_c_string(&logger::last_warning(), &mut out.message);
        }
        true
    }))
    .unwrap_or(false)
}

/// Enable/disable playback pull mode and set the ring's target depth in frames
/// (clamped to 2048 … ring capacity). Disabling clears queued audio.
#[no_mangle]
pub extern "C" fn cg_spotify_set_playback(enabled: bool, target_frames: u32) {
    let p = plumbing();
    let cap = p.ring.capacity_frames() as u64;
    p.target_frames
        .store(u64::from(target_frames).clamp(2048, cap), Ordering::Release);
    p.enabled.store(enabled, Ordering::Release);
    if !enabled {
        p.ring.request_clear();
        p.last_pull_ms.store(0, Ordering::Release);
    }
}

/// Real-time safe pull of interleaved stereo f32 for the render thread. Fills
/// `out` with up to `frames` frames, zero-fills the rest, returns frames read.
///
/// # Safety
/// `out` must point to at least `frames * 2` writable floats.
#[no_mangle]
pub unsafe extern "C" fn cg_spotify_read_playback(out: *mut f32, frames: u32) -> u32 {
    if out.is_null() || frames == 0 {
        return 0;
    }
    let p = plumbing();
    let channels = usize::from(librespot_playback::NUM_CHANNELS);
    let buf = std::slice::from_raw_parts_mut(out, frames as usize * channels);
    p.last_pull_ms.store(p.now_ms(), Ordering::Release);
    let got = p.ring.pop_into(buf);
    for s in &mut buf[got..] {
        *s = 0.0;
    }
    let got_frames = (got / channels) as u32;
    if got_frames > 0 && got_frames < frames {
        // try_lock: never block the render thread on the status mutex.
        if let Ok(guard) = CURRENT.try_lock() {
            if let Some(cur) = guard.as_ref() {
                cur.underruns.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    got_frames
}

/// Choose how the receiver identifies itself to Spotify for the NEXT start:
/// true = librespot's desktop-Linux speaker (keymaster client id, Linux
/// client-token data — the identity every Raspberry Pi install uses);
/// false = the build target's own identity (iPhone on iOS). Default: true.
#[no_mangle]
pub extern "C" fn cg_spotify_set_persona(desktop_linux: bool) {
    PERSONA_DESKTOP.store(desktop_linux, Ordering::Release);
}

/// Copy the recent sanitised log (oldest first, newline-separated, UTF-8,
/// NUL-terminated, truncated at a char boundary to fit). Returns the bytes
/// copied excluding the NUL. Account names, credential blobs and tokens are
/// redacted before they ever reach this buffer.
///
/// # Safety
/// `out` must point to `capacity` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn cg_spotify_copy_log(out: *mut c_char, capacity: usize) -> usize {
    if out.is_null() || capacity == 0 {
        return 0;
    }
    let text = logger::recent_lines();
    // Keep the newest lines when the buffer is too small.
    let mut start = text.len().saturating_sub(capacity - 1);
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    let bytes = &text.as_bytes()[start..];
    let dst = std::slice::from_raw_parts_mut(out as *mut u8, capacity);
    dst[..bytes.len()].copy_from_slice(bytes);
    dst[bytes.len()] = 0;
    bytes.len()
}

/// Static, NUL-terminated description of the pinned librespot revision.
#[no_mangle]
pub extern "C" fn cg_spotify_librespot_revision() -> *const c_char {
    REVISION_C.as_ptr() as *const c_char
}

// MARK: - Receiver thread

fn runner_main(name: String, tmp_dir: PathBuf, shared: Arc<Shared>, shutdown: oneshot::Receiver<()>) {
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("cg-spotify-tokio")
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            shared.set_message(format!("Could not start the receiver runtime: {e}"));
            shared.set_state(ReceiverState::Failed);
            return;
        }
    };
    let player = rt.block_on(run(name, tmp_dir, shared.clone(), shutdown));
    // Dropping the last Player handle joins librespot's player thread; the
    // sink observes `stop` within ~20 ms, so this is quick.
    drop(player);
    rt.shutdown_timeout(SHUTDOWN_STEP_TIMEOUT);
    shared.set_playback(PlaybackState::Idle);
    if shared.state() != ReceiverState::Failed {
        shared.set_state(ReceiverState::Stopped);
    }
}

type SpircTask = Pin<Box<dyn Future<Output = ()> + Send>>;

async fn run(
    name: String,
    tmp_dir: PathBuf,
    shared: Arc<Shared>,
    mut shutdown: oneshot::Receiver<()>,
) -> Option<Arc<Player>> {
    shared.set_state(ReceiverState::Starting);
    let desktop = PERSONA_DESKTOP.load(Ordering::Acquire);
    // Must precede SessionConfig::default(): the persona picks the client id.
    librespot_core::config::set_platform_persona(desktop);
    let session_config = SessionConfig {
        device_id: device_id_for(&name, desktop),
        tmp_dir,
        ..SessionConfig::default()
    };
    log::info!(
        "persona={} (platform {}) client_id={}… device_id={}…",
        if desktop { "desktop-speaker" } else { "native" },
        librespot_core::config::os(),
        &session_config.client_id[..6],
        &session_config.device_id[..8],
    );

    let backend = match librespot_discovery::find(Some("dns-sd")) {
        Ok(b) => b,
        Err(e) => {
            shared.set_message(format!("Bonjour backend unavailable: {e}"));
            shared.set_state(ReceiverState::Failed);
            return None;
        }
    };
    let port = pick_free_port();
    let discovery = Discovery::builder(session_config.device_id.clone(), session_config.client_id.clone())
        .name(name.clone())
        .device_type(DeviceType::Speaker)
        .port(port)
        .zeroconf_backend(backend)
        .launch();
    let mut discovery = match discovery {
        Ok(d) => d,
        Err(e) => {
            shared.set_message(format!("Could not advertise over Bonjour: {e}"));
            shared.set_state(ReceiverState::Failed);
            return None;
        }
    };
    shared.set_port(port);
    shared.set_message(format!("Advertising \"{name}\" — pick it in Spotify's device list"));
    shared.set_state(ReceiverState::Waiting);
    log::info!("advertising {name:?} on port {port}");

    let mixer: Arc<dyn Mixer> = match SoftMixer::open(MixerConfig::default()) {
        Ok(m) => Arc::new(m),
        Err(e) => {
            shared.set_message(format!("Mixer error: {e}"));
            shared.set_state(ReceiverState::Failed);
            discovery.shutdown().await;
            return None;
        }
    };
    // Analysis sees full-scale PCM (NoOpVolume); Spotify's volume is applied
    // only to what we play out.
    let output_volume = mixer.get_soft_volume();
    let sink_shared = shared.clone();
    let sink_plumbing = plumbing().clone();
    let mut session = Session::new(session_config.clone(), None);
    let player = Player::new(PlayerConfig::default(), session.clone(), Box::new(NoOpVolume), move || {
        Box::new(ChromaSink::new(sink_shared, sink_plumbing, output_volume))
    });
    let events = tokio::spawn(watch_player_events(player.get_player_event_channel(), shared.clone()));

    let connect_config = ConnectConfig {
        name: name.clone(),
        device_type: DeviceType::Speaker,
        ..ConnectConfig::default()
    };

    let mut spirc: Option<Spirc> = None;
    let mut spirc_task: Option<SpircTask> = None;
    let mut credentials: Option<Credentials> = None;
    let mut connecting = false;
    let mut reconnects: Vec<Instant> = Vec::new();

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            next = discovery.next() => match next {
                Some(c) => {
                    log::info!("stage 1/3: zeroconf hand-off received (addUser OK)");
                    shutdown_spirc(&mut spirc, &mut spirc_task).await;
                    if !session.is_invalid() {
                        session.shutdown();
                    }
                    credentials = Some(c);
                    reconnects.clear();
                    connecting = true;
                    shared.set_message("Spotify picked this device — connecting");
                    shared.set_state(ReceiverState::Connecting);
                }
                None => {
                    shared.set_message("Bonjour/zeroconf stopped unexpectedly (check Local Network permission)");
                    shared.set_state(ReceiverState::Failed);
                    break;
                }
            },
            _ = async {}, if connecting && credentials.is_some() => {
                connecting = false;
                if session.is_invalid() {
                    session = Session::new(session_config.clone(), None);
                    player.set_session(session.clone());
                }
                let creds = credentials.clone().unwrap_or_default();
                log::info!("stage 2/3: logging in to Spotify and starting Connect");
                shared.set_message("Logging in to Spotify…");
                let setup = tokio::time::timeout(
                    SESSION_SETUP_TIMEOUT,
                    Spirc::new(connect_config.clone(), session.clone(), creds, player.clone(), mixer.clone()),
                ).await;
                let setup = match setup {
                    Ok(result) => result.map_err(|e| e.to_string()),
                    Err(_) => Err(format!("timed out after {} s (see log for the last step)", SESSION_SETUP_TIMEOUT.as_secs())),
                };
                match setup {
                    Ok((s, task)) => {
                        log::info!("stage 3/3: Spotify Connect ready — device should show as connected");
                        spirc = Some(s);
                        spirc_task = Some(Box::pin(task));
                        shared.set_message("Connected — play something in Spotify");
                        shared.set_state(ReceiverState::Connected);
                    }
                    Err(e) => {
                        log::warn!("could not initialise Spotify Connect: {e}");
                        shared.set_message(format!("Spotify refused the session: {e}"));
                        if !session.is_invalid() {
                            session.shutdown();
                        }
                        credentials = None;
                        // Keep advertising: picking the device again retries.
                        shared.set_state(ReceiverState::Waiting);
                    }
                }
            },
            _ = async {
                if let Some(task) = spirc_task.as_mut() {
                    task.await;
                }
            }, if spirc_task.is_some() && !connecting => {
                spirc_task = None;
                spirc = None;
                shared.set_playback(PlaybackState::Idle);
                reconnects.retain(|t| t.elapsed() < RECONNECT_WINDOW);
                if credentials.is_some() && reconnects.len() < RECONNECT_LIMIT {
                    reconnects.push(Instant::now());
                    if !session.is_invalid() {
                        session.shutdown();
                    }
                    log::warn!("Spotify Connect session ended — reconnecting");
                    shared.set_message("Connection dropped — reconnecting");
                    shared.set_state(ReceiverState::Connecting);
                    connecting = true;
                } else {
                    credentials = None;
                    shared.set_message("Spotify session ended — pick ChromaGlow Sync again in Spotify");
                    shared.set_state(ReceiverState::Waiting);
                }
            },
        }
    }

    // Orderly teardown: no zombie Connect device, no lingering mDNS record.
    shared.stop.store(true, Ordering::Release);
    shutdown_spirc(&mut spirc, &mut spirc_task).await;
    let _ = tokio::time::timeout(SHUTDOWN_STEP_TIMEOUT, discovery.shutdown()).await;
    if !session.is_invalid() {
        session.shutdown();
    }
    events.abort();
    Some(player)
}

async fn shutdown_spirc(spirc: &mut Option<Spirc>, task: &mut Option<SpircTask>) {
    if let Some(s) = spirc.take() {
        if let Err(e) = s.shutdown() {
            log::warn!("spirc shutdown: {e}");
        }
    }
    if let Some(t) = task.take() {
        let _ = tokio::time::timeout(SHUTDOWN_STEP_TIMEOUT, t).await;
    }
}

async fn watch_player_events(mut events: PlayerEventChannel, shared: Arc<Shared>) {
    while let Some(event) = events.recv().await {
        match event {
            PlayerEvent::Loading { .. } => shared.set_playback(PlaybackState::Loading),
            PlayerEvent::Playing { .. } => shared.set_playback(PlaybackState::Playing),
            PlayerEvent::Paused { .. } => shared.set_playback(PlaybackState::Paused),
            PlayerEvent::Stopped { .. } => shared.set_playback(PlaybackState::Idle),
            PlayerEvent::Unavailable { .. } => shared.set_message("Spotify says this track is unavailable here"),
            PlayerEvent::VolumeChanged { volume } => shared.set_volume(volume),
            PlayerEvent::TrackChanged { audio_item } => {
                let artist = match &audio_item.unique_fields {
                    UniqueFields::Track { artists, .. } => artists
                        .0
                        .iter()
                        .map(|a| a.name.clone())
                        .collect::<Vec<_>>()
                        .join(", "),
                    UniqueFields::Episode { show_name, .. } => show_name.clone(),
                    UniqueFields::Local { artists, .. } => artists.clone().unwrap_or_default(),
                };
                shared.set_track(audio_item.name.clone(), artist);
            }
            PlayerEvent::SessionClientChanged { client_name, .. } => shared.set_remote_client(client_name),
            PlayerEvent::SessionDisconnected { .. } => {
                shared.set_playback(PlaybackState::Idle);
                shared.set_remote_client(String::new());
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_id_is_stable_and_name_scoped() {
        assert_eq!(device_id_for("ChromaGlow Sync", true), device_id_for("ChromaGlow Sync", true));
        assert_ne!(device_id_for("ChromaGlow Sync", true), device_id_for("Other", true));
        assert_ne!(device_id_for("ChromaGlow Sync", true), device_id_for("ChromaGlow Sync", false));
        assert_eq!(device_id_for("ChromaGlow Sync", false).len(), 40);
    }

    #[test]
    fn revision_string_matches_pin() {
        let s = std::str::from_utf8(&REVISION_C[..REVISION_C.len() - 1]).unwrap();
        assert!(s.ends_with(LIBRESPOT_REVISION));
    }
}

#[cfg(test)]
mod persona_tests {
    use super::*;

    #[test]
    fn persona_switches_the_librespot_identity() {
        librespot_core::config::set_platform_persona(true);
        assert_eq!(librespot_core::config::os(), "linux");
        assert_eq!(SessionConfig::default().client_id, "65b708073fc0480ea92a077233ca87bd");
        librespot_core::config::set_platform_persona(false);
        assert_eq!(librespot_core::config::os(), std::env::consts::OS);
    }

    #[test]
    fn copied_log_is_bounded_and_terminated() {
        logger::install();
        log::info!("persona_test line one");
        log::info!("persona_test line two");
        let mut buf = [1 as c_char; 32];
        let n = unsafe { cg_spotify_copy_log(buf.as_mut_ptr(), buf.len()) };
        assert!(n <= 31);
        assert_eq!(buf[n], 0);
        let text: Vec<u8> = buf[..n].iter().map(|c| *c as u8).collect();
        assert!(String::from_utf8(text).unwrap().ends_with("line two\n"), "newest lines kept");
    }
}
