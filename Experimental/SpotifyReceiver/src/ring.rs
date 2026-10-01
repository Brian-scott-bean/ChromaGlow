//! Lock-free single-producer / single-consumer ring of interleaved f32 samples.
//!
//! Producer: the librespot player thread (inside `ChromaSink::write`).
//! Consumer: the iOS render thread (`cg_spotify_read_playback`), which must
//! never block, allocate or take a contended lock. Counters are monotonically
//! increasing (wrapping) sample indices; capacity is a power of two.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

pub struct SpscRing {
    buf: Box<[UnsafeCell<f32>]>,
    mask: usize,
    channels: usize,
    write: AtomicUsize,
    read: AtomicUsize,
    clear_requested: AtomicBool,
}

// SAFETY: the producer only writes slots in [write, read + cap) and the
// consumer only reads slots in [read, write); the Release/Acquire pairs on the
// two counters order those accesses. One producer and one consumer at a time
// is the documented contract of every caller in this crate.
unsafe impl Sync for SpscRing {}
unsafe impl Send for SpscRing {}

impl SpscRing {
    /// `capacity_samples` is rounded up to a power of two.
    pub fn new(capacity_samples: usize, channels: usize) -> Self {
        let cap = capacity_samples.next_power_of_two().max(channels * 64);
        let buf = (0..cap).map(|_| UnsafeCell::new(0.0f32)).collect::<Vec<_>>();
        Self {
            buf: buf.into_boxed_slice(),
            mask: cap - 1,
            channels,
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            clear_requested: AtomicBool::new(false),
        }
    }

    pub fn capacity_frames(&self) -> usize {
        (self.mask + 1) / self.channels
    }

    /// Frames currently queued. Safe from any thread (a snapshot).
    pub fn len_frames(&self) -> usize {
        let w = self.write.load(Ordering::Acquire);
        let r = self.read.load(Ordering::Acquire);
        w.wrapping_sub(r) / self.channels
    }

    /// Producer only. Pushes whole frames; returns the samples accepted.
    pub fn push(&self, data: &[f32]) -> usize {
        let w = self.write.load(Ordering::Relaxed);
        let r = self.read.load(Ordering::Acquire);
        let free = (self.mask + 1) - w.wrapping_sub(r);
        let n = data.len().min(free) / self.channels * self.channels;
        for (i, sample) in data.iter().take(n).enumerate() {
            // SAFETY: slot (w + i) is outside the consumer's readable window.
            unsafe { *self.buf[(w.wrapping_add(i)) & self.mask].get() = *sample };
        }
        self.write.store(w.wrapping_add(n), Ordering::Release);
        n
    }

    /// Consumer only (real-time safe). Pops whole frames; returns samples written.
    pub fn pop_into(&self, out: &mut [f32]) -> usize {
        if self.clear_requested.swap(false, Ordering::AcqRel) {
            let w = self.write.load(Ordering::Acquire);
            self.read.store(w, Ordering::Release);
        }
        let r = self.read.load(Ordering::Relaxed);
        let w = self.write.load(Ordering::Acquire);
        let avail = w.wrapping_sub(r);
        let n = out.len().min(avail) / self.channels * self.channels;
        for (i, slot) in out.iter_mut().take(n).enumerate() {
            // SAFETY: slot (r + i) was published by the producer's Release store.
            *slot = unsafe { *self.buf[(r.wrapping_add(i)) & self.mask].get() };
        }
        self.read.store(r.wrapping_add(n), Ordering::Release);
        n
    }

    /// Drop everything queued. Honoured by the consumer on its next pop, so
    /// the consumer stays the only writer of `read`.
    pub fn request_clear(&self) {
        self.clear_requested.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::SpscRing;

    #[test]
    fn push_pop_preserves_order_and_frames() {
        let ring = SpscRing::new(16, 2);
        assert_eq!(ring.push(&[1.0, 2.0, 3.0, 4.0, 5.0]), 4, "only whole frames");
        assert_eq!(ring.len_frames(), 2);
        let mut out = [0.0f32; 3];
        assert_eq!(ring.pop_into(&mut out), 2, "only whole frames");
        assert_eq!(&out[..2], &[1.0, 2.0]);
        let mut rest = [0.0f32; 8];
        assert_eq!(ring.pop_into(&mut rest), 2);
        assert_eq!(&rest[..2], &[3.0, 4.0]);
    }

    #[test]
    fn full_ring_refuses_and_wraps() {
        let ring = SpscRing::new(8, 2);
        let cap = ring.capacity_frames() * 2;
        let data: Vec<f32> = (0..cap as i32 + 4).map(|v| v as f32).collect();
        assert_eq!(ring.push(&data), cap);
        assert_eq!(ring.push(&[9.0, 9.0]), 0, "bounded: never grows");
        let mut out = vec![0.0f32; 4];
        ring.pop_into(&mut out);
        assert_eq!(ring.push(&[7.0, 8.0]), 2, "space reclaimed after a pop");
    }

    #[test]
    fn clear_is_applied_by_consumer() {
        let ring = SpscRing::new(64, 2);
        ring.push(&[1.0; 32]);
        ring.request_clear();
        let mut out = [0.0f32; 32];
        assert_eq!(ring.pop_into(&mut out), 0);
        assert_eq!(ring.len_frames(), 0);
    }
}
