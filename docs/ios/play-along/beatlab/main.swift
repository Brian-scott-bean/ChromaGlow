// main.swift — beat lab runner: today's pipeline (repo files, unmodified)
// vs the proposed V2 tracker, on identical synthetic room audio.

import Foundation

struct Snap { var t: Double; var s: BeatSnapshot; var conf: Double = 0; var raw: Double = 0 }

struct Stats {
    var name = ""
    var beats = 0, unlocked = 0, tempoOK = 0, doubleT = 0, halfT = 0, otherT = 0
    var errorsMs: [Double] = []
    var downbeatsChecked = 0, downbeatsOK = 0
    var lockTime: Double? = nil

    func line() -> String {
        let n = max(1, beats)
        let sortedAbs = errorsMs.map { abs($0) }.sorted()
        func pct(_ p: Double) -> Double { sortedAbs.isEmpty ? .nan : sortedAbs[min(sortedAbs.count - 1, Int(Double(sortedAbs.count) * p))] }
        let bias = errorsMs.isEmpty ? Double.nan : errorsMs.reduce(0, +) / Double(errorsMs.count)
        let w30 = errorsMs.isEmpty ? 0 : Double(sortedAbs.filter { $0 <= 30 }.count) / Double(sortedAbs.count) * 100
        let w50 = errorsMs.isEmpty ? 0 : Double(sortedAbs.filter { $0 <= 50 }.count) / Double(sortedAbs.count) * 100
        let db = downbeatsChecked > 0 ? Double(downbeatsOK) / Double(downbeatsChecked) * 100 : .nan
        return String(format: "%@ tempoOK %3.0f%% (x2 %2.0f%% x½ %2.0f%% other %2.0f%% none %2.0f%%) | phase med %5.1f p90 %5.1f bias %+6.1f ms | ≤30ms %3.0f%% ≤50ms %3.0f%% | bar-1 %3.0f%% | lock %@",
                      name.padding(toLength: 4, withPad: " ", startingAt: 0),
                      Double(tempoOK) / Double(n) * 100, Double(doubleT) / Double(n) * 100, Double(halfT) / Double(n) * 100,
                      Double(otherT) / Double(n) * 100, Double(unlocked) / Double(n) * 100,
                      pct(0.5), pct(0.9), bias, w30, w50, db, lockTime.map { String(format: "%.1fs", $0) } ?? "—")
    }
}

func evaluate(_ name: String, snaps: [Snap], beats: [(time: Double, bpm: Double, isDownbeat: Bool)],
              warmup: Double, segmentStarts: [Double]) -> Stats {
    var st = Stats(); st.name = name
    var idx = 0
    var consecutiveGood = 0
    for b in beats {
        // Skip beats within `warmup` seconds of their segment's start.
        let segStart = segmentStarts.last { $0 <= b.time + 1e-9 } ?? 0
        guard b.time - segStart >= warmup else { continue }
        while idx + 1 < snaps.count && snaps[idx + 1].t <= b.time { idx += 1 }
        guard idx < snaps.count, snaps[idx].t <= b.time else { st.unlocked += 1; st.beats += 1; continue }
        let s = snaps[idx].s
        st.beats += 1
        guard s.bpm > 0 else { st.unlocked += 1; consecutiveGood = 0; continue }
        let r = s.bpm / b.bpm
        if abs(r - 1) < 0.02 { st.tempoOK += 1 }
        else if abs(r - 2) < 0.04 { st.doubleT += 1 }
        else if abs(r - 0.5) < 0.01 { st.halfT += 1 }
        else { st.otherT += 1 }
        if abs(r - 1) < 0.02 || abs(r - 2) < 0.04 {
            let ph = s.beatPhase(at: b.time)
            let e = (ph < 0.5 ? ph : ph - 1) * s.beatInterval * 1000
            st.errorsMs.append(e)
            if abs(e) <= 50 { consecutiveGood += 1 } else { consecutiveGood = 0 }
            if consecutiveGood >= 4, st.lockTime == nil { st.lockTime = b.time - segStart }
            if abs(r - 1) < 0.02, b.isDownbeat {
                st.downbeatsChecked += 1
                let bp = s.barPhase(at: b.time) * Double(s.beatsPerBar)
                let wrapped = bp > Double(s.beatsPerBar) / 2 ? bp - Double(s.beatsPerBar) : bp
                if abs(wrapped) < 0.5 { st.downbeatsOK += 1 }
            }
        } else { consecutiveGood = 0 }
    }
    return st
}

/// Seconds from a segment's first beat until the grid holds ≤50 ms for 4 straight beats.
func lockTimes(snaps: [Snap], beats: [(time: Double, bpm: Double, isDownbeat: Bool)], segmentStarts: [Double]) -> [Double?] {
    var out: [Double?] = []
    for (si, segStart) in segmentStarts.enumerated() {
        let segEnd = si + 1 < segmentStarts.count ? segmentStarts[si + 1] : .infinity
        var good = 0
        var found: Double? = nil
        var idx = 0
        for b in beats where b.time >= segStart && b.time < segEnd {
            while idx + 1 < snaps.count && snaps[idx + 1].t <= b.time { idx += 1 }
            guard idx < snaps.count, snaps[idx].t <= b.time, snaps[idx].s.bpm > 0 else { good = 0; continue }
            let s = snaps[idx].s
            let r = s.bpm / b.bpm
            guard abs(r - 1) < 0.02 || abs(r - 2) < 0.04 || abs(r - 0.5) < 0.01 else { good = 0; continue }
            let ph = s.beatPhase(at: b.time)
            let e = (ph < 0.5 ? ph : ph - 1) * s.beatInterval * 1000
            if abs(e) <= 50 { good += 1 } else { good = 0 }
            if good >= 4 { found = b.time - segStart; break }
        }
        out.append(found)
    }
    return out
}

/// Beats in each segment's first `window` seconds — the re-lock period the
/// warm-up skips — where the grid CLAIMS a usable lock (phase confidence ≥
/// 0.5, what Play Along engages on and the readout shows) but is more than
/// 50 ms off. Returns (claimed, wrong) counts.
func falseLocks(snaps: [Snap], beats: [(time: Double, bpm: Double, isDownbeat: Bool)],
                segmentStarts: [Double], window: Double = 10) -> (claimed: Int, wrong: Int) {
    var claimed = 0, wrong = 0, idx = 0
    for b in beats {
        let segStart = segmentStarts.last { $0 <= b.time + 1e-9 } ?? 0
        guard b.time - segStart < window else { continue }
        while idx + 1 < snaps.count && snaps[idx + 1].t <= b.time { idx += 1 }
        guard idx < snaps.count, snaps[idx].t <= b.time else { continue }
        let s = snaps[idx].s
        guard s.bpm > 0, s.phaseConfidence >= 0.5 else { continue }
        claimed += 1
        let r = s.bpm / b.bpm
        // A half-time grid (the tracker's deliberate choice at 174) is right
        // when every real beat lands on one of its beats or half-way between.
        let half = abs(r - 0.5) < 0.01
        var ph = s.beatPhase(at: b.time)
        if half { ph = (ph * 2).truncatingRemainder(dividingBy: 1) }
        let e = (ph < 0.5 ? ph : ph - 1) * s.beatInterval * (half ? 0.5 : 1) * 1000
        if !(abs(r - 1) < 0.02 || abs(r - 2) < 0.04 || half) || abs(e) > 50 { wrong += 1 }
    }
    return (claimed, wrong)
}

/// Share of snapshots (after warm-up) where the clock claims a confident lock.
func claimsLock(_ snaps: [Snap], after t0: Double) -> Double {
    let s = snaps.filter { $0.t >= t0 }
    guard !s.isEmpty else { return 0 }
    return Double(s.filter { $0.s.bpm > 0 && $0.conf >= 0.5 }.count) / Double(s.count) * 100
}

let B = 4800   // what iOS actually delivers per tap at 48 kHz (~100 ms)

@MainActor
func runV1(_ r: Rendered) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    let extractor = AudioFeatureExtractor()
    let estimator = TempoEstimator()
    var snaps: [Snap] = []
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * B <= r.samples.count {
            let start = Double(k * B) / r.fs
            let arrival = start + Double(B) / r.fs + 0.004
            let mid = start + Double(B) / r.fs / 2
            _ = extractor.process(data: p.baseAddress! + k * B, frameCount: B, sampleRate: Float(r.fs),
                                  hostTime: arrival, captureTime: mid)
            if k % 5 == 4 {
                let s = extractor.onsetEnvelopeSnapshot()
                if let est = estimator.update(onsetEnvelope: s.envelope, hopRate: s.hopRate) {
                    clock.ingest(estimate: est, endTime: s.endTime)
                }
                snaps.append(Snap(t: arrival + 0.01, s: BeatClock.snapshot(), conf: clock.confidence))
            }
            k += 1
        }
    }
    return snaps
}

@MainActor
func runV2(_ r: Rendered, confThreshold: Double = 0.30, bar: Bool, log: Bool = false, opts: V2Options = V2Options()) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    let odf = OnsetODF(fs: r.fs)
    let tp = TempoPhaseV2(frameRate: r.fs / 480)
    tp.minSeconds = opts.minSeconds
    tp.silenceReset = opts.silenceReset
    // Type-2 PLL state (period from integrated phase error).
    var pllPeriod = 0.0, pllBeat = 0.0
    var snaps: [Snap] = []
    var lastPick = -1, pickRun = 0
    var lastRaw = 0.0
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * B <= r.samples.count {
            let start = Double(k * B) / r.fs
            let arrival = start + Double(B) / r.fs + 0.004
            odf.push(p.baseAddress! + k * B, count: B, bufferStartTime: start)
            if k % 5 == 4, let tEnd = odf.times.last {
                tp.bandHistory = odf.bands
                tp.allHigh = odf.high
                if let e = tp.update(odf: odf.odf, low: odf.low, mid: odf.mid, times: odf.times) {
                    if log && k % 50 == 4 {
                        print(String(format: "   t=%5.1f bpm %6.2f conf %.2f peak %.2f bar %d barConf %.2f", tEnd, e.bpm, e.confidence, e.rawPeakRatio, e.downbeatPhaseBeats ?? -1, e.barConfidence))
                    }
                    lastRaw = e.confidence
                    var feedBPM = e.bpm
                    if opts.pll {
                        let acfPeriod = 60 / e.bpm
                        if pllPeriod == 0 || abs(pllPeriod / acfPeriod - 1) > 0.04 {
                            pllPeriod = acfPeriod; pllBeat = e.lastBeatTime
                        } else {
                            // predicted beat nearest the measured one
                            let nBeats = ((e.lastBeatTime - pllBeat) / pllPeriod).rounded()
                            let predicted = pllBeat + nBeats * pllPeriod
                            let err = e.lastBeatTime - predicted
                            if nBeats >= 1 {
                                pllPeriod += 0.35 * err / nBeats          // integral path → tempo
                                pllPeriod += 0.05 * (acfPeriod - pllPeriod) // weak pull to the ACF tempo
                            }
                            pllBeat = e.lastBeatTime
                        }
                        feedBPM = 60 / pllPeriod
                    }
                    let est = TempoEstimate(bpm: feedBPM, confidence: e.confidence >= confThreshold ? 0.9 : 0.1,
                                            lastBeatOffset: tEnd - e.lastBeatTime)
                    clock.ingest(estimate: est, endTime: tEnd)
                    if bar, let d = e.downbeatPhaseBeats, e.barConfidence > 0.05, clock.bpm > 0 {
                        // Bar re-anchor by WHOLE beats only (never moves the beat phase):
                        // downbeats sit at beat indices ≡ d (mod 4) counted from lastBeat.
                        let snap = BeatClock.snapshot()
                        let n0 = Int(((e.lastBeatTime - snap.beatEpoch) / snap.beatInterval).rounded())
                        let m = (((n0 + d) % 4) + 4) % 4
                        if m == lastPick { pickRun += 1 } else { lastPick = m; pickRun = 1 }
                        if m != 0, pickRun >= 3 {
                            clock.nudgePhase(ms: Double(m) * snap.beatInterval * 1000)
                        }
                    }
                }
                snaps.append(Snap(t: arrival + 0.01, s: BeatClock.snapshot(), conf: clock.confidence, raw: lastRaw))
            }
            k += 1
        }
    }
    return snaps
}

struct Case { var name: String; var segments: [Segment]; var noiseDB: Double = -24; var seed: UInt64 = 7; var rhythmic = true }

let cases: [Case] = [
    Case(name: "120 rock", segments: [Segment(bpm: 120, leadIn: 0.37, bars: 24)]),
    Case(name: "128 rock", segments: [Segment(bpm: 128, leadIn: 0.21, bars: 32)]),
    Case(name: "100.5 rock", segments: [Segment(bpm: 100.5, leadIn: 0.6, bars: 20)]),
    Case(name: "87 rock", segments: [Segment(bpm: 87, leadIn: 0.15, bars: 16)]),
    Case(name: "140 rock", segments: [Segment(bpm: 140, leadIn: 0.44, bars: 32)]),
    Case(name: "174 dnb-ish", segments: [Segment(bpm: 174, leadIn: 0.12, bars: 40)]),
    Case(name: "124 house 4otf", segments: [Segment(bpm: 124, leadIn: 0.3, bars: 32, kickOnAllFour: true)]),
    Case(name: "120 noisy -12dB", segments: [Segment(bpm: 120, leadIn: 0.37, bars: 24)], noiseDB: -12),
    Case(name: "112 live drift ±2%", segments: [Segment(bpm: 112, leadIn: 0.5, bars: 28, driftPct: 2, driftPeriod: 16)]),
    Case(name: "96 swing 8ths", segments: [Segment(bpm: 96, leadIn: 0.3, bars: 20, swing: 0.16)]),
    Case(name: "song change 128→96", segments: [Segment(bpm: 128, leadIn: 0.2, bars: 16, gapAfter: 1.5),
                                                Segment(bpm: 96, leadIn: 0.0, bars: 16)]),
    Case(name: "ambient pad only", segments: [Segment(bpm: 70, leadIn: 0.2, bars: 14, drums: false, bass: false)], rhythmic: false),
    Case(name: "speech-like bursts", segments: [Segment(bpm: 100, leadIn: 0.2, bars: 16, drums: false, bass: false, pad: false, bursts: true)], rhythmic: false),
    Case(name: "noise only", segments: [Segment(bpm: 100, leadIn: 0.2, bars: 16, drums: false, bass: false, pad: false)], rhythmic: false),
]

let args = CommandLine.arguments
let verbose = args.contains("-v")
if args.contains("-service") { serviceReport(); exit(0) }
if args.contains("-import") { importCorpus(args); exit(0) }
if args.contains("-selftest") {
    // The room's FFT convolution against a direct sum, on random signals.
    var rng = SplitMix(s: 11)
    var worst: Float = 0
    for (n, m) in [(1000, 37), (50_000, 4_800), (200_000, 30_000), (300_000, 47_945), (400_000, 72_000)] {
        let x = (0..<n).map { _ in Float(rng.gauss()) }, h = (0..<m).map { _ in Float(rng.gauss()) * 0.05 }
        let fast = RoomSim.convolve(x, h)
        for k in stride(from: 0, to: n, by: max(1, n / 997)) {
            var direct: Float = 0
            for j in 0...min(k, m - 1) { direct += x[k - j] * h[j] }
            worst = max(worst, abs(direct - fast[k]))
        }
    }
    print(String(format: "convolution: worst |FFT − direct| %.2e", worst))
    exit(worst < 1e-3 ? 0 : 1)
}
if let i = args.firstIndex(of: "-metrics"), i + 2 < args.count {
    // Cross-check against mir_eval: two files of beat times → F CMLc CMLt AMLc AMLt.
    func times(_ p: String) -> [Double] {
        ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    }
    let ref = times(args[i + 1]), est = times(args[i + 2])
    let c = Metrics.continuity(ref: ref, est: est)
    print(String(format: "%.6f %.6f %.6f %.6f %.6f", Metrics.beatF(ref: ref, est: est), c.cmlC, c.cmlT, c.amlC, c.amlT))
    exit(0)
}
if args.contains("-corpus") { MainActor.assumeIsolated { corpusReport(args) }; exit(0) }
if args.contains("-drums") { drumReport(args, detectors: [("today's hit", legacyOnsets)]); exit(0) }
if args.contains("-tracktune") { MainActor.assumeIsolated { trackTune(args) }; exit(0) }
if args.contains("-onset") { onsetLatencyReport(); exit(0) }
if args.contains("-cpu") {
    let r = Synth.render([Segment(bpm: 124, leadIn: 0.3, bars: 60)], seed: 3)
    let secs = Double(r.samples.count) / r.fs
    MainActor.assumeIsolated {
        var t0 = Date(); _ = runV1(r); let v1 = Date().timeIntervalSince(t0)
        t0 = Date(); _ = runV2(r, bar: true, opts: V2Options(minSeconds: 3, silenceReset: true, pll: true)); let v2 = Date().timeIntervalSince(t0)
        print(String(format: "audio %.0f s | v1 %.1f ms CPU per s of audio | v2++ %.1f ms CPU per s of audio (prototype, unoptimised, M-series Mac)", secs, v1 / secs * 1000, v2 / secs * 1000))
    }
    exit(0)
}
if args.contains("-bar") {
    print("ROCK 128"); debugBar(Segment(bpm: 128, leadIn: 0.21, bars: 16))
    print("HOUSE 124"); debugBar(Segment(bpm: 124, leadIn: 0.3, bars: 16, kickOnAllFour: true))
    exit(0)
}
MainActor.assumeIsolated {
    for c in cases {
        let r = Synth.render(c.segments, seed: c.seed, noiseDB: c.noiseDB)
        var segStarts: [Double] = []
        var t = 0.0
        for s in c.segments {
            segStarts.append(t + s.leadIn)
            let beatsLen = r.beats.filter { $0.time >= t + s.leadIn - 1e-9 }.prefix(s.bars * 4)
            let segLen = (beatsLen.last.map { $0.time - (t + s.leadIn) + 60 / $0.bpm } ?? Double(s.bars * 4) * 60 / s.bpm)
            t += s.leadIn + segLen + s.gapAfter
        }
        print("── \(c.name)  (\(String(format: "%.0f", Double(r.samples.count) / r.fs)) s)")
        let s1 = runV1(r), s2 = runV2(r, bar: false, log: verbose), s3 = runV2(r, bar: true)
        let s4 = runV2(r, bar: true, opts: V2Options(minSeconds: 3, silenceReset: true, pll: true))
        let s5 = runProd(r), s6 = runProd(r, hop: 4800)
        if c.rhythmic {
            for (name, snaps) in [("v1", s1), ("v2", s2), ("v2+b", s3), ("v2++", s4), ("prod", s5)] {
                var st = evaluate(name, snaps: snaps, beats: r.beats, warmup: 10, segmentStarts: segStarts)
                st.lockTime = nil
                let locks = lockTimes(snaps: snaps, beats: r.beats, segmentStarts: segStarts)
                    .map { $0.map { String(format: "%.1fs", $0) } ?? "never" }.joined(separator: "/")
                print("  " + st.line().replacingOccurrences(of: "| lock —", with: "| lock " + locks))
            }
            // What ships, scored from each song's first beat: the warm-up
            // above hides exactly the re-lock period.
            var all = evaluate("prod", snaps: s5, beats: r.beats, warmup: 0, segmentStarts: segStarts)
            all.lockTime = nil
            let fl = falseLocks(snaps: s5, beats: r.beats, segmentStarts: segStarts)
            print("  " + all.line().replacingOccurrences(of: "prod", with: "p@0 ").replacingOccurrences(of: "| lock —", with: "")
                  + String(format: "| first 10 s: claims a lock on %d beats, %d of them >50 ms off", fl.claimed, fl.wrong))
            // The same tracker fed the old tap's ~100 ms buffers (before chunk 2).
            var tap = evaluate("prod", snaps: s6, beats: r.beats, warmup: 0, segmentStarts: segStarts)
            tap.lockTime = nil
            let ftap = falseLocks(snaps: s6, beats: r.beats, segmentStarts: segStarts)
            print("  " + tap.line().replacingOccurrences(of: "prod", with: "tap0").replacingOccurrences(of: "| lock —", with: "")
                  + String(format: "| first 10 s: claims a lock on %d beats, %d of them >50 ms off", ftap.claimed, ftap.wrong))
        } else {
            print(String(format: "  v1 claims a confident lock %3.0f%% of the time; v2 %3.0f%%; v2++ %3.0f%%; prod %3.0f%% (v2 raw conf mean %.2f max %.2f)",
                         claimsLock(s1, after: 5), claimsLock(s2, after: 5), claimsLock(s4, after: 5), claimsLock(s5, after: 5),
                         s2.filter { $0.t > 5 }.map(\.raw).reduce(0, +) / Double(max(1, s2.filter { $0.t > 5 }.count)),
                         s2.map(\.raw).max() ?? 0))
        }
    }
}
