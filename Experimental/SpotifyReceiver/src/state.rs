//! Per-run shared state: the PCM callback gate, counters and the status the
//! Swift side polls. One `Shared` per `cg_spotify_start` generation.

use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

/// Hot-path PCM callback (C ABI). Invoked on the librespot player thread with
/// interleaved f32 samples. `queued_frames` is how many frames were already
/// waiting in the playback ring ahead of this chunk (0 when not playing out).
pub type PcmCallback = extern "C" fn(
    generation: u64,
    samples: *const f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    queued_frames: u32,
);

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceiverState {
    Stopped = 0,
    Starting = 1,
    /// Advertised over Bonjour; waiting for a Spotify app to pick it.
    Waiting = 2,
    /// Credentials handed over; logging in / starting Connect.
    Connecting = 3,
    Connected = 4,
    Failed = 5,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackState {
    Idle = 0,
    Loading = 1,
    Playing = 2,
    Paused = 3,
}

/// Whether this device holds Spotify Connect playback (CGSpotifyStatus.handoff).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handoff {
    /// Not yet picked in this session.
    None = 0,
    /// The active Connect device: Spotify plays here.
    Active = 1,
    /// Was active, then Spotify moved playback elsewhere (e.g. the phone's
    /// own Spotify app reclaimed it when the iPhone's output route changed).
    MovedAway = 2,
}

#[derive(Default)]
struct Text {
    title: String,
    artist: String,
    remote_client: String,
    message: String,
}

pub struct Shared {
    pub generation: u64,
    /// Set the moment stop is requested: no PCM callback fires after this.
    pub stop: AtomicBool,
    pcm_callback: Option<PcmCallback>,
    state: AtomicU32,
    playback: AtomicU32,
    zeroconf_port: AtomicU32,
    volume: AtomicU32,
    track_serial: AtomicU32,
    pub frames_delivered: AtomicU64,
    pub chunks_delivered: AtomicU64,
    last_peak_bits: AtomicU32,
    pub underruns: AtomicU64,
    /// Nanoseconds (since `epoch`) of a play request still waiting for its
    /// first PCM chunk; 0 = none pending.
    pending_play_ns: AtomicU64,
    first_pcm_ms: AtomicU32,
    handoff: AtomicU32,
    position_ms: AtomicU32,
    /// Nanoseconds (since `epoch`) when `position_ms` was reported.
    position_at_ns: AtomicU64,
    duration_ms: AtomicU32,
    epoch: Instant,
    text: Mutex<Text>,
}

impl Shared {
    pub fn new(generation: u64, pcm_callback: Option<PcmCallback>) -> Self {
        Self {
            generation,
            stop: AtomicBool::new(false),
            pcm_callback,
            state: AtomicU32::new(ReceiverState::Starting as u32),
            playback: AtomicU32::new(PlaybackState::Idle as u32),
            zeroconf_port: AtomicU32::new(0),
            volume: AtomicU32::new(u32::from(u16::MAX / 2)),
            track_serial: AtomicU32::new(0),
            frames_delivered: AtomicU64::new(0),
            chunks_delivered: AtomicU64::new(0),
            last_peak_bits: AtomicU32::new(0),
            underruns: AtomicU64::new(0),
            pending_play_ns: AtomicU64::new(0),
            first_pcm_ms: AtomicU32::new(0),
            handoff: AtomicU32::new(Handoff::None as u32),
            position_ms: AtomicU32::new(0),
            position_at_ns: AtomicU64::new(0),
            duration_ms: AtomicU32::new(0),
            epoch: Instant::now(),
            text: Mutex::new(Text::default()),
        }
    }

    pub fn is_stopping(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    /// Hand one chunk to Swift. Real-time-ish: no allocation, no lock.
    pub fn deliver_pcm(&self, interleaved: &[f32], channels: u32, sample_rate: u32, queued_frames: u32) {
        if self.is_stopping() {
            return;
        }
        let frames = (interleaved.len() as u32) / channels.max(1);
        if frames == 0 {
            return;
        }
        let mut peak = 0.0f32;
        for s in interleaved {
            peak = peak.max(s.abs());
        }
        self.last_peak_bits.store(peak.to_bits(), Ordering::Relaxed);
        let pending = self.pending_play_ns.load(Ordering::Relaxed);
        if pending != 0
            && self
                .pending_play_ns
                .compare_exchange(pending, 0, Ordering::AcqRel, Ordering::Relaxed)
                .is_ok()
        {
            let now = self.epoch.elapsed().as_nanos() as u64;
            let ms = now.saturating_sub(pending) / 1_000_000;
            self.first_pcm_ms.store(ms.min(u64::from(u32::MAX)) as u32, Ordering::Relaxed);
        }
        self.frames_delivered.fetch_add(u64::from(frames), Ordering::Relaxed);
        self.chunks_delivered.fetch_add(1, Ordering::Relaxed);
        if let Some(cb) = self.pcm_callback {
            cb(self.generation, interleaved.as_ptr(), frames, channels, sample_rate, queued_frames);
        }
    }

    pub fn set_state(&self, state: ReceiverState) {
        self.state.store(state as u32, Ordering::Release);
    }

    pub fn state(&self) -> ReceiverState {
        match self.state.load(Ordering::Acquire) {
            0 => ReceiverState::Stopped,
            1 => ReceiverState::Starting,
            2 => ReceiverState::Waiting,
            3 => ReceiverState::Connecting,
            4 => ReceiverState::Connected,
            _ => ReceiverState::Failed,
        }
    }

    pub fn set_playback(&self, playback: PlaybackState) {
        let previous = self.playback.swap(playback as u32, Ordering::AcqRel);
        // Start the play→first-PCM stopwatch on Loading, or on Playing that
        // resumes from idle/paused (resume has no Loading event).
        let starts = match playback {
            PlaybackState::Loading => true,
            PlaybackState::Playing => previous != PlaybackState::Playing as u32
                && previous != PlaybackState::Loading as u32,
            _ => false,
        };
        if starts {
            let now = (self.epoch.elapsed().as_nanos() as u64).max(1);
            self.pending_play_ns.store(now, Ordering::Release);
        }
    }

    pub fn set_handoff(&self, handoff: Handoff) {
        self.handoff.store(handoff as u32, Ordering::Release);
    }

    pub fn handoff(&self) -> Handoff {
        match self.handoff.load(Ordering::Acquire) {
            1 => Handoff::Active,
            2 => Handoff::MovedAway,
            _ => Handoff::None,
        }
    }

    /// Track position as of now (librespot reports it on play/pause/seek).
    pub fn set_position(&self, position_ms: u32) {
        self.position_ms.store(position_ms, Ordering::Release);
        self.position_at_ns
            .store(self.epoch.elapsed().as_nanos() as u64, Ordering::Release);
    }

    pub fn set_duration(&self, duration_ms: u32) {
        self.duration_ms.store(duration_ms, Ordering::Release);
    }

    pub fn set_port(&self, port: u16) {
        self.zeroconf_port.store(u32::from(port), Ordering::Release);
    }

    pub fn set_volume(&self, volume: u16) {
        self.volume.store(u32::from(volume), Ordering::Release);
    }

    pub fn set_track(&self, title: String, artist: String) {
        let mut text = self.text.lock().unwrap_or_else(|e| e.into_inner());
        text.title = title;
        text.artist = artist;
        drop(text);
        self.track_serial.fetch_add(1, Ordering::AcqRel);
    }

    pub fn set_remote_client(&self, name: String) {
        self.text.lock().unwrap_or_else(|e| e.into_inner()).remote_client = name;
    }

    /// Latest human-readable note (error or progress). Never carries secrets:
    /// callers pass librespot error *kinds*, and the logger redacts account ids.
    pub fn set_message(&self, message: impl Into<String>) {
        self.text.lock().unwrap_or_else(|e| e.into_inner()).message = message.into();
    }

    pub fn fill_status(&self, out: &mut CGSpotifyStatus, ring_queued_frames: u32) {
        out.generation = self.generation;
        out.state = self.state.load(Ordering::Acquire);
        out.playback = self.playback.load(Ordering::Acquire);
        out.sample_rate = librespot_playback::SAMPLE_RATE;
        out.channels = u32::from(librespot_playback::NUM_CHANNELS);
        out.zeroconf_port = self.zeroconf_port.load(Ordering::Acquire);
        out.volume = self.volume.load(Ordering::Acquire);
        out.track_serial = self.track_serial.load(Ordering::Acquire);
        out.frames_delivered = self.frames_delivered.load(Ordering::Relaxed);
        out.chunks_delivered = self.chunks_delivered.load(Ordering::Relaxed);
        out.last_peak = f32::from_bits(self.last_peak_bits.load(Ordering::Relaxed));
        out.underruns = self.underruns.load(Ordering::Relaxed);
        out.playback_queued_frames = ring_queued_frames;
        out.first_pcm_ms = self.first_pcm_ms.load(Ordering::Relaxed);
        out.handoff = self.handoff.load(Ordering::Acquire);
        out.position_ms = self.position_ms.load(Ordering::Acquire);
        let now = self.epoch.elapsed().as_nanos() as u64;
        let age_ms = now.saturating_sub(self.position_at_ns.load(Ordering::Acquire)) / 1_000_000;
        out.position_age_ms = age_ms.min(u64::from(u32::MAX)) as u32;
        out.duration_ms = self.duration_ms.load(Ordering::Acquire);
        let text = self.text.lock().unwrap_or_else(|e| e.into_inner());
        copy_c_string(&text.title, &mut out.title);
        copy_c_string(&text.artist, &mut out.artist);
        copy_c_string(&text.remote_client, &mut out.remote_client);
        copy_c_string(&text.message, &mut out.message);
    }
}

/// Mirrors `CGSpotifyStatus` in include/chromaglow_spotify.h — keep in lockstep.
#[repr(C)]
pub struct CGSpotifyStatus {
    pub generation: u64,
    pub state: u32,
    pub playback: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub zeroconf_port: u32,
    pub volume: u32,
    pub track_serial: u32,
    pub playback_queued_frames: u32,
    /// Play request → first PCM chunk, last measured (ms; 0 = none yet).
    pub first_pcm_ms: u32,
    /// `Handoff` as u32.
    pub handoff: u32,
    /// Track position when last reported, and how long ago that was; the
    /// current position is `position_ms + position_age_ms` while playing.
    pub position_ms: u32,
    pub position_age_ms: u32,
    pub duration_ms: u32,
    pub frames_delivered: u64,
    pub chunks_delivered: u64,
    pub underruns: u64,
    pub last_peak: f32,
    pub title: [c_char; 256],
    pub artist: [c_char; 256],
    pub remote_client: [c_char; 128],
    pub message: [c_char; 256],
}

/// Copies UTF-8 into a fixed C buffer, truncating on a char boundary, always
/// NUL-terminated.
pub fn copy_c_string(src: &str, dst: &mut [c_char]) {
    if dst.is_empty() {
        return;
    }
    let max = dst.len() - 1;
    let mut end = src.len().min(max);
    while end > 0 && !src.is_char_boundary(end) {
        end -= 1;
    }
    for (i, b) in src.as_bytes()[..end].iter().enumerate() {
        dst[i] = *b as c_char;
    }
    dst[end] = 0;
}

#[cfg(test)]
mod tests {
    use super::copy_c_string;

    #[test]
    fn c_string_truncates_on_char_boundary() {
        let mut buf = [1 as std::os::raw::c_char; 4];
        copy_c_string("aé漢", &mut buf); // 'a'(1) + 'é'(2) fit; '漢'(3) does not
        assert_eq!(buf[3], 0);
        let bytes: Vec<u8> = buf.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
        assert_eq!(String::from_utf8(bytes).unwrap(), "aé");
    }
}

#[cfg(test)]
mod latency_tests {
    use super::{CGSpotifyStatus, PlaybackState, Shared};

    #[test]
    fn first_pcm_latency_is_measured_once_per_play_request() {
        let shared = Shared::new(1, None);
        shared.set_playback(PlaybackState::Loading);
        std::thread::sleep(std::time::Duration::from_millis(15));
        shared.deliver_pcm(&[0.5, -0.5, 0.25, -0.25], 2, 44_100, 0);
        let mut st: CGSpotifyStatus = unsafe { std::mem::zeroed() };
        shared.fill_status(&mut st, 0);
        assert!(st.first_pcm_ms >= 15, "measured {} ms", st.first_pcm_ms);
        assert_eq!(st.frames_delivered, 2);
        assert!((st.last_peak - 0.5).abs() < f32::EPSILON);
        // Loading → Playing is the same request: no new stopwatch.
        shared.set_playback(PlaybackState::Playing);
        shared.deliver_pcm(&[0.1, 0.1], 2, 44_100, 0);
        shared.fill_status(&mut st, 0);
        assert!(st.first_pcm_ms >= 15);
    }

    #[test]
    fn stopped_gate_drops_pcm() {
        let shared = Shared::new(7, None);
        shared.stop.store(true, std::sync::atomic::Ordering::Release);
        shared.deliver_pcm(&[1.0, 1.0], 2, 44_100, 0);
        let mut st: CGSpotifyStatus = unsafe { std::mem::zeroed() };
        shared.fill_status(&mut st, 0);
        assert_eq!(st.frames_delivered, 0);
        assert_eq!(st.generation, 7);
    }
}

#[cfg(test)]
mod handoff_tests {
    use super::{CGSpotifyStatus, Handoff, Shared};

    #[test]
    fn handoff_and_position_reach_the_status() {
        let shared = Shared::new(3, None);
        let mut st: CGSpotifyStatus = unsafe { std::mem::zeroed() };
        shared.fill_status(&mut st, 0);
        assert_eq!(st.handoff, Handoff::None as u32);
        shared.set_handoff(Handoff::Active);
        shared.set_duration(200_000);
        shared.set_position(78_000);
        std::thread::sleep(std::time::Duration::from_millis(12));
        shared.fill_status(&mut st, 0);
        assert_eq!(st.handoff, Handoff::Active as u32);
        assert_eq!((st.position_ms, st.duration_ms), (78_000, 200_000));
        assert!(st.position_age_ms >= 12);
        shared.set_handoff(Handoff::MovedAway);
        assert_eq!(shared.handoff(), Handoff::MovedAway);
    }
}

#[cfg(test)]
mod layout_tests {
    #[test]
    fn status_layout_is_pinned() {
        // HueHomeTests/SpotifyPCMExperimentTests asserts the same numbers from
        // the Swift import of include/chromaglow_spotify.h.
        assert_eq!(std::mem::size_of::<super::CGSpotifyStatus>(), 992);
        assert_eq!(std::mem::align_of::<super::CGSpotifyStatus>(), 8);
    }
}
