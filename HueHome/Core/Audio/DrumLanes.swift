// DrumLanes.swift
// ChromaGlow — Core/Audio ("the room is the band", step 1: build 915)
//
// Kick, snare and hi-hat, each heard on its own, from the same 10 ms analysis
// frames the beat tracker uses (OnsetFrameAnalyzer's 18 log bands):
//  • kick: the bass bands (30–188 Hz) rising together;
//  • snare: its body (188–469 Hz) AND its noise (2–7 kHz) rising together;
//  • hi-hat (and the band's other metal — ride, crash): 5–16 kHz rising.
// A rise is measured against the louder of the last two frames (so a slow
// swell or a vibrato isn't a hit) and judged against that lane's own recent
// level and spread, with a minimum gap per drum. Tuned on annotated drums
// (Groove MIDI, BabySlakh) clean and through measured rooms in the beat lab
// (docs/ios/play-along/beatlab, `run.sh -drums`, `-drumtune`, `-kickbass`).
//
// Kick vs bass (README §21): each kick band is a single 47 Hz FFT bin, so a
// bass note that starts from silence rises like a kick. The lane tells them
// apart by loudness — a kick must bring the low end near the loudest it has
// been lately — and not by waiting for the decay, which would publish kicks
// 80–120 ms late for no better score. Known limit: a bass line in a song
// with no drums at all still reads as kicks.
//
// THREADING CONTRACT: owned by the analyzer's producer thread; `process`
// allocates nothing.

import Foundation

struct DrumLaneTuning: Sendable, Equatable {
    // Tuned in the beat lab (`run.sh -drumtune`, then `-kickbass`, 2026-11-02):
    // 24 Groove MIDI takes and 20 BabySlakh mixes, clean and through measured
    // home-like rooms, each lane's settings chosen for its mean F.
    var kickBands: ClosedRange<Int> = 0...2
    var snareBodyBands: ClosedRange<Int> = 3...5
    var snareNoiseBands: ClosedRange<Int> = 11...14
    var hatBands: ClosedRange<Int> = 14...17
    /// Firing threshold: the lane's running mean + `k` × its running mean
    /// absolute deviation (both over about `memory` seconds).
    var kickK: Float = 5
    var snareK: Float = 0.5
    var hatK: Float = 2
    var memory: Double = 0.75
    /// A rise below this (log units summed over the lane's bands) never fires.
    /// The snare's is what mostly decides it: body and noise rising together
    /// by this much is a snare.
    var kickFloor: Float = 2
    var snareFloor: Float = 1.5
    var hatFloor: Float = 0.3
    /// Minimum gap between two hits of one drum.
    var kickGap: Double = 0.09
    var snareGap: Double = 0.06
    var hatGap: Double = 0.07
    /// Kick: share of the beater's click (1–5 kHz rising with it) mixed into
    /// the kick lane. The lab found it no help (a bass note's attack has the
    /// click too), so it is off.
    var kickClick: Float = 0
    /// Kick confirmation: a kick dies away, a bass note sustains. A kick
    /// candidate is confirmed only if the bass bands fall by `kickDecay` (log
    /// units, summed over the kick bands) from their peak within
    /// `kickConfirmFrames` frames. The hit keeps its onset time; it is
    /// published that many frames later (0 = no confirmation). Off: on the
    /// lab's mixes 12 frames (+120 ms) only matched the precision the level
    /// gate reaches without waiting, at a lower F.
    var kickConfirmFrames: Int = 0
    var kickDecay: Float = 1
    /// A snare doesn't fire on a frame the kick lane fired on (a kick's
    /// click plus a bass note's harmonics look like a snare), nor within
    /// `snareVetoWindow` seconds after one.
    var snareVetoOnKick: Bool = true
    var snareVetoWindow: Double = 0.05
    /// A snare is held this many frames before it is published (it keeps its
    /// onset time) and dropped if the kick lane fires meanwhile: a kick's
    /// click reaches the snare's noise bands a frame before its low end
    /// clears the kick lane.
    var snareHoldFrames: Int = 1
    /// Kick vs bass without waiting: a kick candidate must bring the bass
    /// bands to within this much (log units, summed) of the loudest low end
    /// lately. A kick is usually the loudest thing down there; a bass note
    /// that starts from silence rises as steeply but stops lower. "Lately"
    /// fades by about a fifth per second, so a bass note a beat after a kick
    /// is held to the kick's level, and about a second after the last kick
    /// bass notes pass again (a drum break with the bass going on reads as
    /// kicks). Off when infinite. At 2 (summed over the three kick bins):
    /// mix precision 0.62 → 0.70, kick F 0.76 → 0.78.
    var kickLevelGate: Float = 2

    static let standard = DrumLaneTuning()
}

final class DrumLanes {
    enum Kind: Int, CaseIterable, Sendable { case kick, snare, hat }

    struct Hit: Sendable, Equatable {
        var time: Double
        /// 0…1: how hard, against the lane's recent loudest.
        var strength: Float
    }

    /// A reader of the analyzer's frame ring sees a held or confirmed hit
    /// marked back on its onset frame at most this long after that frame.
    static let settleSeconds = 0.15

    /// The latest hit of each drum (time 0 = none yet).
    private(set) var last: [Hit] = Array(repeating: Hit(time: 0, strength: 0), count: Kind.allCases.count)
    var lastKickTime: Double { last[0].time }
    var lastSnareTime: Double { last[1].time }

    let tuning: DrumLaneTuning
    private let bandCount: Int
    private var history: [Float]          // the last two frames' band levels
    private var frames = 0
    private var mean: [Float] = [0, 0, 0]
    private var deviation: [Float] = [0, 0, 0]
    private var peak: [Float] = [1, 1, 1]
    private var alpha: Float = 0.01
    // A kick waiting for confirmation: its onset time, strength, frames since,
    // and the bass bands' peak level since the onset.
    private var pendingKick: (time: Double, strength: Float, frames: Int, peakLevel: Float)?
    // A snare held for `snareHoldFrames`: onset time, strength, frames since.
    private var pendingSnare: (time: Double, strength: Float, frames: Int)?
    // The loudest low end lately (the kick bands' summed log level), fading with
    // a 4 s time constant (about a fifth per second).
    private var lowPeak: Float = 0

    init(bandCount: Int = OnsetFrameAnalyzer.bandCount, tuning: DrumLaneTuning = .standard) {
        self.bandCount = bandCount
        self.tuning = tuning
        history = [Float](repeating: 0, count: bandCount * 2)
    }

    func reset() {
        frames = 0
        for i in history.indices { history[i] = 0 }
        mean = [0, 0, 0]
        deviation = [0, 0, 0]
        peak = [1, 1, 1]
        pendingKick = nil
        pendingSnare = nil
        lowPeak = 0
        last = Array(repeating: Hit(time: 0, strength: 0), count: Kind.allCases.count)
    }

    /// One analysis frame (`levels`: the frame's band levels, log-compressed;
    /// `time`: its capture time). Returns each drum's strength if it fired
    /// on this frame, else 0.
    @discardableResult
    func process(levels: UnsafeBufferPointer<Float>, time: Double, frameRate: Double) -> (kick: Float, snare: Float, hat: Float) {
        guard levels.count >= bandCount else { return (0, 0, 0) }
        alpha = Float(min(1, 1 / max(1, tuning.memory * frameRate)))
        defer {
            // Shift: history[0..<n] = two frames ago, history[n..<2n] = last frame.
            for b in 0..<bandCount {
                history[b] = history[bandCount + b]
                history[bandCount + b] = levels[b]
            }
            frames += 1
        }
        guard frames >= 2 else { return (0, 0, 0) }

        func level(_ bands: ClosedRange<Int>) -> Float {
            var s: Float = 0
            for b in bands where b < bandCount { s += levels[b] }
            return s
        }
        func rise(_ bands: ClosedRange<Int>) -> Float {
            var s: Float = 0
            for b in bands where b < bandCount {
                let ref = max(history[b], history[bandCount + b])
                s += max(0, levels[b] - ref)
            }
            return s
        }

        // Kick: the bass bands, with an optional share of the beater's click.
        var kick = rise(tuning.kickBands)
        if tuning.kickClick > 0 { kick *= 1 + tuning.kickClick * rise(9...13) }
        // Snare: body and noise together (their geometric mean, so neither
        // alone fires it).
        let snare = (rise(tuning.snareBodyBands) * rise(tuning.snareNoiseBands)).squareRoot()
        let hat = rise(tuning.hatBands)
        let warm = frames > Int(0.5 * frameRate)
        var kickOut: Float = 0
        let kickLevel = level(tuning.kickBands)
        if var p = pendingKick {
            // Waiting: confirm once the bass bands have fallen far enough from
            // their peak; give up when the window closes.
            p.frames += 1
            p.peakLevel = max(p.peakLevel, kickLevel)
            if p.peakLevel - kickLevel >= tuning.kickDecay {
                last[0] = Hit(time: p.time, strength: p.strength)
                kickOut = p.strength
                pendingKick = nil
            } else if p.frames >= tuning.kickConfirmFrames {
                pendingKick = nil
            } else {
                pendingKick = p
            }
        }
        var loudEnough = true
        if tuning.kickLevelGate.isFinite {
            lowPeak = max(kickLevel, lowPeak * (1 - Float(1 / (4 * frameRate))))
            loudEnough = kickLevel >= lowPeak - tuning.kickLevelGate
        }
        let kickFired = judge(0, kick, k: tuning.kickK, floor: tuning.kickFloor, gap: tuning.kickGap, time: time,
                              frameRate: frameRate, warm: warm, allowed: loudEnough,
                              publish: tuning.kickConfirmFrames == 0)
        if kickFired > 0 {
            if tuning.kickConfirmFrames == 0 {
                kickOut = kickFired
            } else {
                pendingKick = (time, kickFired, 0, kickLevel)
            }
        }
        // A kick's beater click and a bass note's harmonics together look like
        // a snare: on a frame the kick lane fired, the snare may not.
        var snareOut: Float = 0
        if var p = pendingSnare {
            p.frames += 1
            if kickFired > 0 {
                pendingSnare = nil
            } else if p.frames >= tuning.snareHoldFrames {
                last[1] = Hit(time: p.time, strength: p.strength)
                snareOut = p.strength
                pendingSnare = nil
            } else {
                pendingSnare = p
            }
        }
        let kickRecently = kickFired > 0
            || time - max(last[0].time, pendingKick?.time ?? 0) < tuning.snareVetoWindow
        let snareFired = judge(1, snare, k: tuning.snareK, floor: tuning.snareFloor, gap: tuning.snareGap, time: time,
                               frameRate: frameRate, warm: warm, allowed: !(tuning.snareVetoOnKick && kickRecently),
                               publish: tuning.snareHoldFrames == 0)
        if snareFired > 0 {
            if tuning.snareHoldFrames == 0 {
                snareOut = snareFired
            } else {
                pendingSnare = (time, snareFired, 0)
            }
        }
        return (kickOut, snareOut,
                judge(2, hat, k: tuning.hatK, floor: tuning.hatFloor, gap: tuning.hatGap, time: time,
                      frameRate: frameRate, warm: warm))
    }

    /// Fire `lane` when `v` clears its running level by `k` deviations, then
    /// update the running level. Returns the hit's strength, or 0.
    private func judge(_ lane: Int, _ v: Float, k: Float, floor: Float, gap: Double, time: Double, frameRate: Double,
                       warm: Bool, allowed: Bool = true, publish: Bool = true) -> Float {
        var fired: Float = 0
        // A candidate still waiting to be published counts as the last hit
        // for the gap.
        let lastTime = lane == 0 ? max(last[0].time, pendingKick?.time ?? 0)
            : lane == 1 ? max(last[1].time, pendingSnare?.time ?? 0) : last[lane].time
        if warm, allowed, v > mean[lane] + k * deviation[lane], v > floor, time - lastTime >= gap {
            peak[lane] = max(v, peak[lane])
            fired = min(1, v / max(peak[lane], 1e-6))
            if publish { last[lane] = Hit(time: time, strength: fired) }
        }
        // The running level forgets slowly; the loudest recent hit decays over
        // about ten seconds so strength stays relative to the song.
        mean[lane] += (v - mean[lane]) * alpha
        deviation[lane] += (abs(v - mean[lane]) - deviation[lane]) * alpha
        peak[lane] = max(1e-3, peak[lane] * (1 - Float(1 / (10 * frameRate))))
        return fired
    }
}
