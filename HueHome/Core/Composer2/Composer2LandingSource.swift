// Composer2LandingSource.swift
// ChromaGlow — Composer 2 (Play Along P4: On the One)
//
// A look switch that lands on the beat. Switching looks while one plays used
// to swap the whole frame source at once — wherever the music was. With On
// the One, the playback center installs this wrapper instead: the outgoing
// look keeps playing, and over the last eighth of a bar (≤ 250 ms) the room
// crossfades into the incoming look, complete exactly on the next bar line —
// half bar or beat when the clock is less sure where bars start (see
// `Composer2Quantizer`). After the landing it simply plays the incoming
// look; the playback center's heartbeat then unwraps it.
//
// Lock-guarded like the outputs it wraps (chunk 2): the Entertainment loop
// renders it off the main actor while the playback center reads the landing
// on the main actor. Reads no clocks: the landing is computed from the first
// frame's `hostNow` (+ the render lead), i.e. the moment that frame is shown.

import Foundation

final class Composer2LandingSource: ConcurrentCompositionFrameSource, @unchecked Sendable {
    let outgoing: Composer2LiveOutput
    let incoming: Composer2LiveOutput

    private let lock = NSLock()
    /// Shown-time of the boundary the incoming look lands on.
    var landing: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _landing
    }
    private var _landing: Double?
    private var preroll: Double = 0
    /// The incoming look owns the room.
    var hasLanded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasLanded
    }
    private var _hasLanded = false

    init(outgoing: Composer2LiveOutput, incoming: Composer2LiveOutput) {
        self.outgoing = outgoing
        self.incoming = incoming
    }

    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        renderLiveFrames(time: time, channelIDs: channelIDs, layout: CompositionLiveLayout(params: params),
                         features: features, beat: beat, hostNow: hostNow)
    }

    func renderLiveFrames(time: Double, channelIDs: [Int], layout: CompositionLiveLayout,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        // Held across both renders: this lock is only ever taken before an
        // output's own, never inside one, so the order is always the same.
        lock.lock()
        defer { lock.unlock() }
        // The incoming look renders every frame — its state warms up and the
        // playback center's heartbeat sees it alive while it waits.
        let next = incoming.renderLiveFrames(time: time, channelIDs: channelIDs, layout: layout,
                                             features: features, beat: beat, hostNow: hostNow)
        if _hasLanded { return next }

        let lead = layout.outputLead.isFinite ? Composer2Math.clamp(layout.outputLead, 0, 1) : 0
        let shown = hostNow + lead
        if _landing == nil {
            if let target = Composer2Quantizer.landing(after: shown, beat: beat) {
                _landing = target.time
                preroll = Composer2Quantizer.preroll(for: beat)
            } else {
                _landing = shown
                preroll = 0
            }
        }
        let weight = Composer2Quantizer.weight(at: shown, landing: _landing ?? shown, preroll: preroll)
        if weight >= 1 {
            _hasLanded = true
            return next
        }
        let previous = outgoing.renderLiveFrames(time: time, channelIDs: channelIDs, layout: layout,
                                                 features: features, beat: beat, hostNow: hostNow)
        guard weight > 0, previous.count == next.count else { return previous.isEmpty ? next : previous }
        return zip(previous, next).map { a, b in
            LightFrame(channelID: b.channelID,
                       x: Composer2Math.lerp(a.x, b.x, weight),
                       y: Composer2Math.lerp(a.y, b.y, weight),
                       brightness: Composer2Math.clamp01(Composer2Math.lerp(a.brightness, b.brightness, weight)))
        }
    }

    /// Seconds until the landing at shown-time `t` (nil before the first
    /// frame or after the landing) — the screen's "lands on the one" countdown.
    func remaining(at t: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !_hasLanded, let landing = _landing else { return nil }
        return max(0, landing - t)
    }
}
