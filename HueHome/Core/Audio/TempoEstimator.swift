// TempoEstimator.swift
// ChromaGlow — Core/Audio (DJ upgrade Phase 2)
//
// Pure BPM + beat-phase estimation from the onset-strength envelope that
// AudioFeatureExtractor accumulates (~6 s at ~43 Hz). No I/O, no clocks —
// fully unit-testable on synthetic click tracks.
//
// Method: autocorrelation of the onset envelope over the 60–180 BPM lag
// range, comb-filter harmonic scoring, parabolic peak interpolation,
// octave disambiguation (prefer 84–168 BPM only when the folded octave
// actually has comparable energy), and hysteresis so the reported BPM
// doesn't flap between adjacent estimates.

import Foundation

struct TempoEstimate: Sendable, Equatable {
    var bpm: Double
    var confidence: Double          // 0–1
    /// Seconds before the envelope's end time at which the last beat fell.
    /// Caller converts to absolute time: lastBeatAt = endTime - lastBeatOffset.
    var lastBeatOffset: Double
}

final class TempoEstimator: @unchecked Sendable {

    // ── Hysteresis state (single-caller contract: the ~2 Hz tempo pass) ──
    private var currentBPM: Double = 0
    private var candidateBPM: Double = 0
    private var candidateWins = 0
    /// Consecutive wins a new BPM needs before it replaces the current one.
    private static let winsToSwitch = 3
    /// BPM difference below which two estimates count as "the same".
    private static let sameBPMTolerance = 3.0

    /// Analysis range.
    private static let minBPM = 60.0
    private static let maxBPM = 180.0
    /// A lag counts as "strongly correlated" at this fraction of the best
    /// score — the smallest such lag is the tempo (subharmonics at 2×/3× the
    /// period score equally well, but the true period is the shortest one).
    private static let strongLagThreshold = 0.85

    /// Run one tempo pass. Returns nil when the envelope is too short or
    /// too quiet to say anything (current BPM state is preserved).
    func update(onsetEnvelope: [Float], hopRate: Double) -> TempoEstimate? {
        let n = onsetEnvelope.count
        // Need at least ~3 s to see 3+ beats at 60 BPM.
        guard hopRate > 1, n >= Int(hopRate * 3.0) else { return nil }

        // Silence / no rhythm → nothing to estimate.
        let energy = onsetEnvelope.reduce(0) { $0 + Double($1) }
        guard energy > 0.01 else { return nil }

        // Mean-remove so DC doesn't dominate the autocorrelation.
        let mean = Float(energy / Double(n))
        let x = onsetEnvelope.map { $0 - mean }

        let minLag = max(2, Int((60.0 / Self.maxBPM) * hopRate))          // 180 BPM
        let maxLag = min(n / 2, Int((60.0 / Self.minBPM) * hopRate) + 1)  // 60 BPM
        guard minLag < maxLag else { return nil }

        // ── Windowed autocorrelation ──
        // The true beat period is rarely an integer number of hops (120 BPM
        // at ~43 Hz is 21.5 hops), so its energy SPLITS across two adjacent
        // integer lags while the half-tempo lag (43) aligns exactly — a raw
        // argmax therefore picks the subharmonic. Summing each lag with its
        // ±1 neighbors re-merges the split energy.
        let maxNeededLag = min(n - 1, 3 * (maxLag + 1) + 1)
        var ac = [Double](repeating: 0, count: maxNeededLag + 1)
        for lag in 1...maxNeededLag {
            var sum: Double = 0
            for i in lag..<n { sum += Double(x[i]) * Double(x[i - lag]) }
            ac[lag] = sum / Double(n - lag)
        }
        func acW(_ lag: Int) -> Double {
            var s = 0.0
            for l in (lag - 1)...(lag + 1) where l >= 1 && l <= maxNeededLag { s += ac[l] }
            return s
        }
        // Comb score: fundamental + harmonics (a real beat also correlates
        // at 2× and 3× its period; noise doesn't).
        func combW(_ lag: Int) -> Double {
            var s = acW(lag)
            if 2 * lag <= maxNeededLag { s += 0.5 * acW(2 * lag) }
            if 3 * lag <= maxNeededLag { s += 0.33 * acW(3 * lag) }
            return s
        }

        var scores = [Double](repeating: 0, count: maxLag + 1)
        var maxScore = -Double.infinity
        var scoreSum: Double = 0
        for lag in minLag...maxLag {
            let s = combW(lag)
            scores[lag] = s
            scoreSum += max(0, s)
            if s > maxScore { maxScore = s }
        }
        guard maxScore > 0 else { return nil }

        // ── Smallest strongly-correlated lag ──
        // A perfect click train at period P correlates equally at P, 2P, 3P…
        // The tempo is the SHORTEST period the signal repeats at, so take the
        // smallest lag whose score is within strongLagThreshold of the best
        // (a true half-tempo track has ~zero energy at the doubled rate and
        // never trips this).
        var clusterStart = maxLag
        for lag in minLag...maxLag where scores[lag] >= maxScore * Self.strongLagThreshold {
            clusterStart = lag
            break
        }
        // The split-energy cluster spans a few adjacent lags — take its peak.
        var bestLag = clusterStart
        for lag in clusterStart...min(clusterStart + 3, maxLag) where scores[lag] > scores[bestLag] {
            bestLag = lag
        }
        let bestScore = scores[bestLag]

        // Parabolic interpolation around the winning lag for sub-hop precision.
        var refinedLag = Double(bestLag)
        let s0 = combW(bestLag - 1), s1 = bestScore, s2 = combW(bestLag + 1)
        let denom = s0 - 2 * s1 + s2
        if abs(denom) > 1e-12 {
            let delta = 0.5 * (s0 - s2) / denom
            if abs(delta) < 1 { refinedLag += delta }
        }

        let bpm = 60.0 * hopRate / refinedLag

        // Confidence: winning peak vs the average score across the range.
        let meanScore = scoreSum / Double(maxLag - minLag + 1)
        let confidence = meanScore > 0 ? min(1.0, max(0, (bestScore / meanScore - 1) / 4)) : 0

        // ── Hysteresis ──
        if currentBPM == 0 {
            currentBPM = bpm
            candidateWins = 0
        } else if abs(bpm - currentBPM) <= Self.sameBPMTolerance {
            // Same tempo — track it smoothly.
            currentBPM = currentBPM * 0.7 + bpm * 0.3
            candidateWins = 0
        } else {
            if abs(bpm - candidateBPM) <= Self.sameBPMTolerance {
                candidateWins += 1
            } else {
                candidateBPM = bpm
                candidateWins = 1
            }
            if candidateWins >= Self.winsToSwitch {
                currentBPM = candidateBPM
                candidateWins = 0
            }
        }

        // ── Beat phase: which offset from the envelope's end best aligns
        // a beat grid at the accepted period with the onset energy? ──
        let period = (60.0 / currentBPM) * hopRate
        let periodInt = max(2, Int(period + 0.5))
        var bestOffset = 0
        var bestPhaseEnergy = -Double.infinity
        for offset in 0..<periodInt {
            var e: Double = 0
            var idx = n - 1 - offset
            while idx >= 0 {
                e += Double(onsetEnvelope[idx])
                idx -= periodInt
            }
            if e > bestPhaseEnergy { bestPhaseEnergy = e; bestOffset = offset }
        }

        return TempoEstimate(
            bpm: currentBPM,
            confidence: confidence,
            lastBeatOffset: Double(bestOffset) / hopRate
        )
    }

    func reset() {
        currentBPM = 0
        candidateBPM = 0
        candidateWins = 0
    }
}
