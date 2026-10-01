//! The in-memory PCM sink. librespot calls `write` on its player thread as
//! fast as the sink accepts audio, so the sink is the clock:
//!
//! * analysis-only (Phase 1): paces itself to wall-clock real time, then hands
//!   each chunk to Swift — nothing is played, nothing is written anywhere;
//! * playback (Phase 2): pushes into the bounded SPSC ring that the iOS render
//!   thread drains, blocking (with a stop check) while the ring is at its
//!   target depth. Analysis still sees the chunk at push time; Swift delays
//!   the lighting by the reported queue depth + output latency.
//!
//! No decoded audio is ever persisted — chunks live in a reused scratch Vec and
//! the fixed-size ring only.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use librespot_playback::audio_backend::{Sink, SinkResult};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::VolumeGetter;
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};

use crate::ring::SpscRing;
use crate::state::Shared;

/// Analysis hop: 1024 frames ≈ 23 ms, the size AudioAnalysisEngine's mic tap requests.
pub const CHUNK_FRAMES: usize = 1024;
/// How far the paced clock may run ahead of real time.
const PACE_LEAD: Duration = Duration::from_millis(30);
/// A stall longer than this re-anchors the clock instead of bursting to catch up.
const PACE_RESYNC: Duration = Duration::from_millis(500);
/// The render thread must have pulled within this window to count as alive.
const CONSUMER_TIMEOUT_MS: u64 = 300;

/// Process-wide playback plumbing (the render thread doesn't know generations).
pub struct PlaybackPlumbing {
    pub ring: SpscRing,
    pub enabled: AtomicBool,
    /// Producer stops pushing once this many frames are queued (latency bound).
    pub target_frames: AtomicU64,
    /// Monotonic ms of the last render-thread pull; 0 = never.
    pub last_pull_ms: AtomicU64,
    epoch: Instant,
}

impl PlaybackPlumbing {
    pub fn new() -> Self {
        Self {
            // 2^17 samples = 65 536 frames ≈ 1.49 s of stereo at 44.1 kHz.
            ring: SpscRing::new(1 << 17, usize::from(NUM_CHANNELS)),
            enabled: AtomicBool::new(false),
            target_frames: AtomicU64::new(u64::from(SAMPLE_RATE) / 4), // 250 ms
            last_pull_ms: AtomicU64::new(0),
            epoch: Instant::now(),
        }
    }

    pub fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64 + 1
    }

    pub fn consumer_alive(&self) -> bool {
        let last = self.last_pull_ms.load(Ordering::Acquire);
        last != 0 && self.now_ms().saturating_sub(last) <= CONSUMER_TIMEOUT_MS
    }
}

struct Pacer {
    origin: Option<Instant>,
    frames: u64,
}

impl Pacer {
    fn reset(&mut self) {
        self.origin = None;
        self.frames = 0;
    }

    /// Sleep until `frames` more frames would have finished playing, in short
    /// slices so a stop request is honoured within ~20 ms.
    fn wait_for(&mut self, frames: usize, shared: &Shared) {
        let now = Instant::now();
        let origin = *self.origin.get_or_insert(now);
        let played = Duration::from_secs_f64(self.frames as f64 / f64::from(SAMPLE_RATE));
        let elapsed = now.duration_since(origin);
        if elapsed > played + PACE_RESYNC {
            // Network stall: re-anchor rather than burst analysis frames.
            self.origin = Some(now - played);
        } else {
            let mut remaining = played.saturating_sub(elapsed + PACE_LEAD);
            while !remaining.is_zero() && !shared.is_stopping() {
                let slice = remaining.min(Duration::from_millis(20));
                thread::sleep(slice);
                remaining = remaining.saturating_sub(slice);
            }
        }
        self.frames += frames as u64;
    }
}

pub struct ChromaSink {
    shared: Arc<Shared>,
    plumbing: Arc<PlaybackPlumbing>,
    output_volume: Box<dyn VolumeGetter + Send>,
    scratch: Vec<f32>,
    scaled: Vec<f32>,
    pacer: Pacer,
}

impl ChromaSink {
    pub fn new(
        shared: Arc<Shared>,
        plumbing: Arc<PlaybackPlumbing>,
        output_volume: Box<dyn VolumeGetter + Send>,
    ) -> Self {
        Self {
            shared,
            plumbing,
            output_volume,
            scratch: Vec::with_capacity(16_384),
            scaled: Vec::with_capacity(CHUNK_FRAMES * usize::from(NUM_CHANNELS)),
            pacer: Pacer { origin: None, frames: 0 },
        }
    }

    /// Push one chunk into the playback ring, waiting (bounded by the stop flag
    /// and consumer liveness) while it sits at its target depth. Returns the
    /// frames that were queued ahead of this chunk, or None when the consumer
    /// is gone and the caller should fall back to wall-clock pacing.
    fn push_for_playback(&mut self, chunk: &[f32]) -> Option<u32> {
        let attenuation = self.output_volume.attenuation_factor() as f32;
        self.scaled.clear();
        self.scaled.extend(chunk.iter().map(|s| s * attenuation));

        let target = self.plumbing.target_frames.load(Ordering::Relaxed) as usize;
        let mut queued_before: Option<u32> = None;
        let mut offset = 0;
        while offset < self.scaled.len() {
            if self.shared.is_stopping() {
                return Some(queued_before.unwrap_or(0));
            }
            if !self.plumbing.enabled.load(Ordering::Acquire) || !self.plumbing.consumer_alive() {
                return queued_before;
            }
            let queued = self.plumbing.ring.len_frames();
            if queued >= target {
                thread::sleep(Duration::from_millis(3));
                continue;
            }
            if queued_before.is_none() {
                queued_before = Some(queued as u32);
            }
            let room = (target - queued) * usize::from(NUM_CHANNELS);
            let end = (offset + room).min(self.scaled.len());
            offset += self.plumbing.ring.push(&self.scaled[offset..end]);
        }
        queued_before
    }
}

impl Sink for ChromaSink {
    fn start(&mut self) -> SinkResult<()> {
        self.pacer.reset();
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        // Pause/stop: the next write re-anchors the clock, and stale queued
        // audio must not play after a pause.
        self.pacer.reset();
        self.plumbing.ring.request_clear();
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, _converter: &mut Converter) -> SinkResult<()> {
        let Ok(samples) = packet.samples() else {
            return Ok(()); // passthrough packets are not built in
        };
        self.scratch.clear();
        self.scratch.extend(samples.iter().map(|s| *s as f32));

        let channels = u32::from(NUM_CHANNELS);
        let chunk_len = CHUNK_FRAMES * usize::from(NUM_CHANNELS);
        let scratch = std::mem::take(&mut self.scratch);
        for chunk in scratch.chunks(chunk_len) {
            if self.shared.is_stopping() {
                break;
            }
            let frames = chunk.len() / usize::from(NUM_CHANNELS);
            let queued = if self.plumbing.enabled.load(Ordering::Acquire) && self.plumbing.consumer_alive() {
                self.push_for_playback(chunk)
            } else {
                None
            };
            match queued {
                Some(q) => {
                    // The ring is the clock while playing out.
                    self.pacer.reset();
                    self.shared.deliver_pcm(chunk, channels, SAMPLE_RATE, q);
                }
                None => {
                    self.pacer.wait_for(frames, &self.shared);
                    self.shared.deliver_pcm(chunk, channels, SAMPLE_RATE, 0);
                }
            }
        }
        self.scratch = scratch;
        Ok(())
    }
}
