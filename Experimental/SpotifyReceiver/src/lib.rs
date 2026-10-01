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
use std::sync::atomic::{AtomicU64, Ordering};
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

fn plumbing() -> &'static Arc<PlaybackPlumbing> {
    PLUMBING.get_or_init(|| Arc::new(PlaybackPlumbing::new()))
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Stable per-name device id so Spotify doesn't accumulate ghost devices.
fn device_id_for(name: &str) -> String {
    let mut h = Sha1::new();
    h.update(b"chromaglow-local-spotify-experiment:");
    h.update(name.as_bytes());
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
    let session_config = SessionConfig {
        device_id: device_id_for(&name),
        tmp_dir,
        ..SessionConfig::default()
    };

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
                    log::info!("credentials received over zeroconf");
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
                match Spirc::new(connect_config.clone(), session.clone(), creds, player.clone(), mixer.clone()).await {
                    Ok((s, task)) => {
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
        assert_eq!(device_id_for("ChromaGlow Sync"), device_id_for("ChromaGlow Sync"));
        assert_ne!(device_id_for("ChromaGlow Sync"), device_id_for("Other"));
        assert_eq!(device_id_for("ChromaGlow Sync").len(), 40);
    }

    #[test]
    fn revision_string_matches_pin() {
        let s = std::str::from_utf8(&REVISION_C[..REVISION_C.len() - 1]).unwrap();
        assert!(s.ends_with(LIBRESPOT_REVISION));
    }
}
