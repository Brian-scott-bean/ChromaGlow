// ActivityLanes.swift
// ChromaGlow — Core/Audio ("the room is the band", step 5: build 919)
//
// The slow lanes: is a bass line playing, are drums playing — decisions over
// about a second, for washes and for the song's shape, not for hits. From the
// same 10 ms analysis frames as the drum lanes (OnsetFrameAnalyzer's 18 log
// bands), our own DSP, every iOS version:
//  • bass: the low end HELD — how quiet the 141–375 Hz bands get over 0.3 s
//    (their 5th-quietest frame of 30: a kick's low end is gone by then, a
//    bass note isn't, and a short gap between two notes doesn't count),
//    against the loudest the whole sound has been lately (30 s);
//  • drums: how hard the top end (≥ 2.8 kHz) swings within 0.3 s (drums are
//    bursts of noise; held notes and chords barely move it), plus how many
//    kicks and snares the drum lanes heard in the last 2 s.
// Both are smoothed over about a second and mapped to 0…1 (0.5 = the
// threshold that best told playing from not playing). Tuned on BabySlakh's
// stems (an instrument "plays" in a 1 s window when its stem is within 20 dB
// of its own loudest), with Groove MIDI and Candombe (drums, no bass) and
// GuitarSet (a guitar alone) as songs where the bass never plays; scored on
// songs not used for tuning (docs/ios/play-along/beatlab, `run.sh -activity`).
//
// Known limits (README §25): a guitar or piano holding the low end reads as
// a bass line (they share its band); strummed guitar on a clean line reads
// partly as drums; a small speaker or a hall blurs both. No vocal lane: there
// is no licence-clean vocal test music yet.
//
// THREADING CONTRACT: owned by the analyzer's producer thread; `process`
// allocates nothing.

import Foundation

struct ActivityTuning: Sendable, Equatable {
    /// The bass line's band: 141–375 Hz (bands 2…4) — its body and first
    /// harmonics, which a small speaker still plays. The bands below hold the
    /// kick as much as the bass.
    var bassBands: ClosedRange<Int> = 2...4
    /// The top end whose swing marks drums (2.8–16 kHz).
    var drumBands: ClosedRange<Int> = 12...17
    /// The window the bass floor and the top end's swing (its maximum −
    /// minimum) are taken over.
    var holdSeconds: Double = 0.3
    /// The bass floor = this-quietest frame of the window (1 = the minimum):
    /// at 5 of 30, gaps of up to 40 ms between notes are passed over.
    var bassRank: Int = 5
    /// How long the loudest whole level is remembered: it falls by one log
    /// unit (≈ 8.7 dB) over this many seconds.
    var peakSeconds: Double = 30
    /// The loudest level never counts below this (log units of the frame's
    /// summed band magnitudes; −1.78 ≈ pink noise at −45 dBFS, 1.15 per
    /// 10 dB): a room's own noise is not a bass line. Steady broadband noise
    /// has a bass line's balance (its 141–375 Hz share reads like one), so
    /// below this level it is ignored; a fan or a vacuum louder than that
    /// reads as a bass line (README §25).
    var peakFloor: Float = -1.78
    /// The window kicks and snares are counted over, and their weight (per
    /// hit in the window) next to the top end's swing.
    var hitSeconds: Double = 2
    var hitWeight: Float = 0.2
    /// Smoothing (time constant, seconds) of both lanes.
    var smoothing: Double = 1
    /// The value that maps to 0.5, and the width of the ramp from 0 to 1.
    /// Tuned on half the songs (`run.sh -activity`).
    var bassCentre: Float = -3.07
    var bassWidth: Float = 1
    var drumCentre: Float = 1.09
    var drumWidth: Float = 1

    static let standard = ActivityTuning()
}

/// The slow lanes' latest values (0…1; 0 before any sound).
struct MusicActivity: Sendable, Equatable {
    var bass: Float = 0
    var drums: Float = 0

    static let none = MusicActivity()
}

final class ActivityLanes {
    let tuning: ActivityTuning
    private let bandCount: Int
    // Rings over the hold window: the bass band's level and the top end's level.
    private var bassRing: [Float]
    private var highRing: [Float]
    // Ring over the hit window: 1 where a kick or snare fired.
    private var hitRing: [UInt8]
    private var scratch: [Float]
    private var holdPos = 0
    private var hitPos = 0
    private var hitCount = 0
    private var frames = 0
    private var peak: Float
    private var bassSmoothed: Float = 0
    private var drumSmoothed: Float = 0
    private var started = false

    /// The latest values.
    private(set) var current = MusicActivity.none

    /// Rings are sized for frame rates up to 200 Hz (the analyzer runs at 100).
    init(bandCount: Int = OnsetFrameAnalyzer.bandCount, tuning: ActivityTuning = .standard) {
        self.bandCount = bandCount
        self.tuning = tuning
        let hold = max(1, Int((tuning.holdSeconds * 200).rounded()))
        bassRing = [Float](repeating: -20, count: hold)
        scratch = [Float](repeating: 0, count: hold)
        highRing = [Float](repeating: -20, count: hold)
        hitRing = [UInt8](repeating: 0, count: max(1, Int((tuning.hitSeconds * 200).rounded())))
        peak = tuning.peakFloor
    }

    func reset() {
        for i in bassRing.indices { bassRing[i] = -20 }
        for i in highRing.indices { highRing[i] = -20 }
        for i in hitRing.indices { hitRing[i] = 0 }
        holdPos = 0; hitPos = 0; hitCount = 0; frames = 0
        peak = tuning.peakFloor
        bassSmoothed = 0; drumSmoothed = 0; started = false
        current = .none
    }

    /// One analysis frame: its band levels (log-compressed, as the
    /// analyzer's `log1p(γ·E)`) and whether the kick or snare lane fired on it.
    @discardableResult
    func process(levels: UnsafeBufferPointer<Float>, kick: Bool, snare: Bool, frameRate: Double) -> MusicActivity {
        guard levels.count >= bandCount, frameRate > 0 else { return current }
        let gamma = OnsetFrameAnalyzer.gamma
        var all: Float = 0, bass: Float = 0, high: Float = 0
        for b in 0..<bandCount {
            let e = expm1f(levels[b]) / gamma
            all += e
            if tuning.bassBands.contains(b) { bass += e }
            if tuning.drumBands.contains(b) { high += e }
        }
        let allLog = logf(all + 1e-5)
        let bassLog = logf(bass + 1e-5)
        // The top end gets the same absolute floor, so the swing of a quiet
        // room's hiss counts for nothing.
        let highLog = logf(high + expf(tuning.peakFloor) * 0.25)

        let hold = min(bassRing.count, max(1, Int((tuning.holdSeconds * frameRate).rounded())))
        bassRing[holdPos % hold] = bassLog
        highRing[holdPos % hold] = highLog
        holdPos = (holdPos + 1) % hold
        let filled = min(frames + 1, hold)
        var highMin = Float.infinity, highMax = -Float.infinity
        for i in 0..<filled {
            scratch[i] = bassRing[i]
            highMin = min(highMin, highRing[i])
            highMax = max(highMax, highRing[i])
        }
        // The bass floor: the rank-th quietest frame (a partial selection sort).
        let rank = min(max(1, tuning.bassRank), filled)
        for r in 0..<rank {
            var m = r
            for i in (r + 1)..<filled where scratch[i] < scratch[m] { m = i }
            scratch.swapAt(r, m)
        }
        let bassFloor = scratch[rank - 1]

        let window = min(hitRing.count, max(1, Int((tuning.hitSeconds * frameRate).rounded())))
        let k = hitPos % window
        if frames >= window { hitCount -= Int(hitRing[k]) }
        hitRing[k] = (kick || snare) ? 1 : 0
        hitCount += Int(hitRing[k])
        hitPos = (hitPos + 1) % window
        frames += 1

        peak = max(allLog, max(tuning.peakFloor, peak - Float(1 / (tuning.peakSeconds * frameRate))))
        let bassValue = bassFloor - peak
        let drumValue = (highMax - highMin) + tuning.hitWeight * Float(hitCount)
        let a = Float(1 - exp(-1 / (max(0.01, tuning.smoothing) * frameRate)))
        if !started {
            // Start from "nothing playing", not from the first frame's value.
            bassSmoothed = tuning.bassCentre - tuning.bassWidth
            drumSmoothed = tuning.drumCentre - tuning.drumWidth
            started = true
        }
        // Smooth the value only near its ramp: far below "off" or above "on"
        // it would take seconds to come back across the threshold.
        func near(_ v: Float, _ centre: Float, _ width: Float) -> Float { min(centre + width, max(centre - width, v)) }
        bassSmoothed += (near(bassValue, tuning.bassCentre, tuning.bassWidth) - bassSmoothed) * a
        drumSmoothed += (near(drumValue, tuning.drumCentre, tuning.drumWidth) - drumSmoothed) * a
        func ramp(_ v: Float, _ centre: Float, _ width: Float) -> Float {
            min(1, max(0, (v - centre) / max(width, 1e-3) + 0.5))
        }
        current = MusicActivity(bass: ramp(bassSmoothed, tuning.bassCentre, tuning.bassWidth),
                                drums: ramp(drumSmoothed, tuning.drumCentre, tuning.drumWidth))
        return current
    }
}
