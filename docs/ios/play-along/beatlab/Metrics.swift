// Metrics.swift — the standard beat and event scores (after mir_eval), so the
// lab's numbers on real songs read like the papers'.
//
//  • F-measure: an estimated beat within ±70 ms of a reference beat is a hit
//    (each beat matched once). Beats before 5 s are ignored, as mir_eval does.
//  • Continuity (CMLc/CMLt/AMLc/AMLt): a beat counts when it is within 17.5 %
//    of the reference interval AND the interval to the previous estimated beat
//    matches the reference interval within 17.5 %. CML is the correct metrical
//    level only; AML also accepts double, half (either phase) and off-beat.
//    "c" = the longest continuous run, "t" = the total.
//  • Events (drum hits, section boundaries): precision/recall/F within a window.

import Foundation

enum Metrics {
    static let beatWindow = 0.07
    static let trimSeconds = 5.0

    struct PRF { var precision: Double; var recall: Double; var f: Double; var hits: Int; var ref: Int; var est: Int }

    /// One-to-one matches between two sorted event lists within ±`window`.
    /// Greedy nearest-first is the maximum matching when the window is less
    /// than half the spacing of either list (true for beats at ±70 ms).
    static func matchCount(_ ref: [Double], _ est: [Double], window: Double) -> Int {
        var pairs: [(d: Double, r: Int, e: Int)] = []
        var j0 = 0
        for (i, r) in ref.enumerated() {
            while j0 < est.count && est[j0] < r - window { j0 += 1 }
            var j = j0
            while j < est.count && est[j] <= r + window {
                pairs.append((abs(est[j] - r), i, j))
                j += 1
            }
        }
        pairs.sort { $0.d < $1.d }
        var usedR = Set<Int>(), usedE = Set<Int>()
        var hits = 0
        for p in pairs where !usedR.contains(p.r) && !usedE.contains(p.e) {
            usedR.insert(p.r); usedE.insert(p.e); hits += 1
        }
        return hits
    }

    static func prf(ref: [Double], est: [Double], window: Double) -> PRF {
        let hits = matchCount(ref, est, window: window)
        let p = est.isEmpty ? 0 : Double(hits) / Double(est.count)
        let r = ref.isEmpty ? 0 : Double(hits) / Double(ref.count)
        let f = p + r > 0 ? 2 * p * r / (p + r) : 0
        return PRF(precision: p, recall: r, f: f, hits: hits, ref: ref.count, est: est.count)
    }

    static func trimmed(_ beats: [Double], from: Double = trimSeconds) -> [Double] { beats.filter { $0 >= from } }

    /// mir_eval.beat.f_measure.
    static func beatF(ref: [Double], est: [Double]) -> Double {
        prf(ref: trimmed(ref), est: trimmed(est), window: beatWindow).f
    }

    struct Continuity { var cmlC: Double; var cmlT: Double; var amlC: Double; var amlT: Double }

    /// mir_eval.beat.continuity (phase and period thresholds 0.175).
    static func continuity(ref rawRef: [Double], est rawEst: [Double],
                           phaseThreshold: Double = 0.175, periodThreshold: Double = 0.175) -> Continuity {
        let ref = trimmed(rawRef), est = trimmed(rawEst)
        guard ref.count >= 2, est.count >= 2 else { return Continuity(cmlC: 0, cmlT: 0, amlC: 0, amlT: 0) }
        var cont: [Double] = [], total: [Double] = []
        for variation in variations(ref) where variation.count >= 2 {
            let n = max(variation.count, est.count)
            var used = [Bool](repeating: false, count: variation.count)
            var success = [Bool](repeating: false, count: n)
            for m in 0..<est.count {
                var nearest = 0
                var best = Double.infinity
                for (k, r) in variation.enumerated() where abs(est[m] - r) < best { best = abs(est[m] - r); nearest = k }
                guard !used[nearest] else { continue }
                let refInterval: Double
                let estInterval: Double
                if m == 0 || nearest == 0 {
                    refInterval = nearest + 1 < variation.count ? variation[nearest + 1] - variation[nearest]
                                                                 : variation[nearest] - variation[nearest - 1]
                    estInterval = m + 1 < est.count ? est[m + 1] - est[m] : est[m] - est[m - 1]
                } else {
                    refInterval = variation[nearest] - variation[nearest - 1]
                    estInterval = est[m] - est[m - 1]
                }
                guard refInterval > 0 else { continue }
                let phase = abs(best / refInterval)
                let period = abs(1 - estInterval / refInterval)
                if phase < phaseThreshold && period < periodThreshold {
                    used[nearest] = true
                    success[m] = true
                }
            }
            var longest = 0, run = 0, count = 0
            for s in success {
                if s { run += 1; count += 1; longest = max(longest, run) } else { run = 0 }
            }
            cont.append(Double(longest) / Double(n))
            total.append(Double(count) / Double(n))
        }
        guard !cont.isEmpty else { return Continuity(cmlC: 0, cmlT: 0, amlC: 0, amlT: 0) }
        return Continuity(cmlC: cont[0], cmlT: total[0], amlC: cont.max()!, amlT: total.max()!)
    }

    /// The reference at its own level, off-beat, double, half (odd), half (even).
    static func variations(_ ref: [Double]) -> [[Double]] {
        var double: [Double] = []
        for i in 0..<ref.count {
            double.append(ref[i])
            if i + 1 < ref.count { double.append((ref[i] + ref[i + 1]) / 2) }
        }
        let offBeat = stride(from: 1, to: double.count, by: 2).map { double[$0] }
        let halfOdd = stride(from: 0, to: ref.count, by: 2).map { ref[$0] }
        let halfEven = stride(from: 1, to: ref.count, by: 2).map { ref[$0] }
        return [ref, offBeat, double, halfOdd, halfEven]
    }

    /// Seconds from `start` until `run` estimated beats in a row each sit within
    /// the beat window of a reference beat (nil: never within `limit`).
    static func lockTime(ref: [Double], est: [Double], from start: Double, run: Int = 4, limit: Double = 30) -> Double? {
        let r = ref.filter { $0 >= start && $0 < start + limit }
        var good = 0
        var j = 0
        for b in r {
            while j < est.count && est[j] < b - beatWindow { j += 1 }
            if j < est.count && abs(est[j] - b) <= beatWindow {
                good += 1
                if good >= run { return b - start }
            } else {
                good = 0
            }
        }
        return nil
    }

    /// Ratio of the estimated to the reference median beat interval: ~1 right
    /// tempo, ~2 the grid runs at half time, ~0.5 double time.
    static func tempoRatio(ref: [Double], est: [Double]) -> Double? {
        func medianIBI(_ b: [Double]) -> Double? {
            guard b.count >= 3 else { return nil }
            let d = zip(b.dropFirst(), b).map { $0 - $1 }.sorted()
            return d[d.count / 2]
        }
        guard let r = medianIBI(ref), let e = medianIBI(est), r > 0 else { return nil }
        return e / r
    }

    static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func mean(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
}
