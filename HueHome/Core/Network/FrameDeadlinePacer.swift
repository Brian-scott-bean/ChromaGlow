// FrameDeadlinePacer.swift
// ChromaGlow — Core/Network (Play Along P0.3)
//
// Deadline pacing for a fixed-rate render loop. The composition stream used
// to render, emit, then sleep a fixed 40 ms AFTER the work — so every frame
// took 40 ms plus its own render, gate and send time, and the loop ran below
// its rate by a different amount every frame. Beat-locked looks sampled the
// clock at those drifting instants.
//
// The pacer keeps a fixed grid instead: each frame sleeps until its own
// slot. A loop that falls more than a whole frame behind (a suspended app, a
// long await) re-anchors on "now" rather than bursting through the missed
// slots to catch up. Pure value type — the clock is passed in.

import Foundation

struct FrameDeadlinePacer {
    let interval: Duration
    private(set) var next: ContinuousClock.Instant

    init(interval: Duration, start: ContinuousClock.Instant) {
        self.interval = interval
        self.next = start + interval
    }

    /// The instant the frame finished at `now` should sleep until. Advances
    /// the grid by one slot.
    mutating func deadline(after now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        if now - next > interval {
            next = now + interval
        }
        let due = next
        next = next + interval
        return due
    }
}
