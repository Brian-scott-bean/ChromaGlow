// TrackTune.swift — tune the shipping tracker's confidence on real music
// (`run.sh -tracktune`). The real-song baseline (results-2026-11-02-corpus.txt)
// found the tracker hearing the right tempo on real drummers and guitarists
// but never trusting it: its confidence reads the autocorrelation at the
// EXACT beat lag, and human timing spreads one-frame onset spikes apart.
//
// Each recording's onset frames are recorded once; the tracker runs once per
// (smoothing, lag tolerance); then every confidence mapping re-maps the
// tracker's raw evidence (periodicity, peakiness) and replays the clock —
// cheap. Scored: the beats the lights would play on real songs (F), and how
// often the clock claims a usable beat on the lab's synthetic non-music
// (speech-like bursts, noise, an ambient pad) — a false lock.

import Foundation

struct FrameTrack {
    var name: String
    var set: String
    var condition: Condition
    var frames: OnsetFrames
    var ref: [Double]
}

/// Every onset frame of a recording, as the analyzer made them.
func recordFrames(_ x: [Float], fs: Double) -> OnsetFrames {
    let analyzer = OnsetFrameAnalyzer()
    let hop = 1024
    var out = OnsetFrames()
    out.frameRate = 100
    out.bandCount = OnsetFrameAnalyzer.bandCount
    var lastTime = -Double.infinity
    x.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= x.count {
            analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: fs, bufferStart: Double(k * hop) / fs)
            if k % 8 == 7 || (k + 2) * hop > x.count {
                let f = analyzer.snapshot(seconds: 0.5)
                out.frameRate = f.frameRate
                for i in 0..<f.count where f.times[i] > lastTime {
                    out.times.append(f.times[i]); out.flux.append(f.flux[i]); out.low.append(f.low[i])
                    out.mid.append(f.mid[i]); out.high.append(f.high[i]); out.energy.append(f.energy[i])
                    out.bands.append(contentsOf: f.bands[(i * f.bandCount)..<((i + 1) * f.bandCount)])
                    lastTime = f.times[i]
                }
            }
            k += 1
        }
    }
    return out
}

/// The frames in (t − seconds, t], as `snapshot(seconds:)` would hand them.
func window(_ f: OnsetFrames, endingAt t: Double, seconds: Double) -> OnsetFrames {
    var lo = 0, hi = f.count
    // First frame > t − seconds; first frame > t.
    var a = 0, b = f.count
    while a < b { let m = (a + b) / 2; if f.times[m] <= t - seconds { a = m + 1 } else { b = m } }
    lo = a
    a = lo; b = f.count
    while a < b { let m = (a + b) / 2; if f.times[m] <= t { a = m + 1 } else { b = m } }
    hi = a
    var w = OnsetFrames()
    w.frameRate = f.frameRate
    w.bandCount = f.bandCount
    guard hi > lo else { return w }
    w.times = Array(f.times[lo..<hi]); w.flux = Array(f.flux[lo..<hi]); w.low = Array(f.low[lo..<hi])
    w.mid = Array(f.mid[lo..<hi]); w.high = Array(f.high[lo..<hi]); w.energy = Array(f.energy[lo..<hi])
    w.bands = Array(f.bands[(lo * f.bandCount)..<(hi * f.bandCount)])
    return w
}

/// One tracker pass every 0.5 s, as the engine runs it: (pass time, observation).
func trackerPasses(_ f: OnsetFrames, tuning: BeatTrackerTuning) -> [(t: Double, o: BeatObservation?)] {
    let tracker = BeatTracker(tuning: tuning)
    var out: [(Double, BeatObservation?)] = []
    guard let end = f.times.last else { return [] }
    var t = 0.5
    while t <= end {
        out.append((t, tracker.update(window(f, endingAt: t, seconds: BeatTracker.windowSeconds + 2))))
        t += 0.5
    }
    return out
}

/// The clock's snapshots for passes whose confidences are re-mapped.
@MainActor
func replayClock(_ passes: [(t: Double, o: BeatObservation?)], floor: Double, span: Double) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    var snaps: [Snap] = []
    for p in passes {
        if var o = p.o {
            o.tempoConfidence = min(1, max(0, (o.periodicity - floor) / span))
            o.phaseConfidence = o.tempoConfidence * min(1, max(0, o.peakiness / 0.6))
            clock.ingest(observation: o)
        } else {
            clock.noteNoBeat(at: p.t)
        }
        snaps.append(Snap(t: p.t + 0.01, s: BeatClock.snapshot(), conf: clock.confidence))
    }
    return snaps
}

@MainActor
func trackTune(_ args: [String]) {
    func list(_ flag: String, _ fallback: [Double]) -> [Double] {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return fallback }
        return args[i + 1].split(separator: ",").compactMap { Double($0) }
    }
    let smooths = list("-smooth", [0, 1, 2, 3, 4]).map { Int($0) }
    let tols = list("-tol", [0, 1, 2]).map { Int($0) }
    let floors = list("-floor", [0.02, 0.05, 0.08, 0.12, 0.16, 0.2])
    let spans = list("-span", [0.1, 0.2, 0.3])
    guard let manifest = try? Corpus.loadManifest() else { print("no manifest"); return }
    let perSet = ["gmd": 60, "slakh": 20, "guitarset": 60, "candombe": 35]
    func load(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: 48_000) } }
    }
    let rirs = load(manifest.rirs)
    var real: [FrameTrack] = []
    let t0 = Date()
    for (set, n) in perSet.sorted(by: { $0.key < $1.key }) {
        let all = manifest.tracks.filter { $0.set == set && $0.beats != nil }
        let step = max(1, all.count / n)
        for track in stride(from: 0, to: all.count, by: step).prefix(n).map({ all[$0] }) {
            guard let ref = try? Corpus.readBeats(Corpus.url(track.beats!)).map(\.time),
                  let audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
            let seed = fnv1a(track.id)
            for cond in [Condition.line, .room] {
                let rir = rirs.isEmpty ? nil : rirs[Int(seed % UInt64(rirs.count))]
                let x = RoomSim.apply(cond, to: audio, fs: 48_000, rir: rir, seed: seed)
                real.append(FrameTrack(name: track.id, set: set, condition: cond, frames: recordFrames(x, fs: 48_000), ref: ref))
            }
        }
    }
    // The lab's synthetic songs: the rhythmic ones must not get worse, the
    // non-music must not lock.
    var synthetic: [(FrameTrack, rhythmic: Bool)] = []
    for c in cases {
        let r = Synth.render(c.segments, seed: c.seed, noiseDB: c.noiseDB)
        synthetic.append((FrameTrack(name: c.name, set: "synthetic", condition: .line, frames: recordFrames(r.samples, fs: r.fs),
                                     ref: r.beats.map(\.time)), c.rhythmic))
    }
    print(String(format: "recorded %d real recordings and %d synthetic in %.0f s", real.count, synthetic.count, Date().timeIntervalSince(t0)))

    struct Row { var name: String; var f: [String: Double]; var synthF: Double; var falseLock: Double }
    var rows: [Row] = []
    for smooth in Set(smooths + [0]).sorted() {
        for tol in Set(tols + [0]).sorted() {
            var tuning = BeatTrackerTuning.raw
            tuning.smoothFrames = smooth
            tuning.lagTolerance = tol
            let realPasses = real.map { trackerPasses($0.frames, tuning: tuning) }
            let synthPasses = synthetic.map { trackerPasses($0.0.frames, tuning: tuning) }
            for floor in Set(floors + [0.2]).sorted() {
                for span in Set(spans + [0.3]).sorted() {
                    var sums: [String: (Double, Int)] = [:]
                    for (i, ft) in real.enumerated() {
                        let p = playedBeats(replayClock(realPasses[i], floor: floor, span: span))
                        let key = "\(ft.set) \(ft.condition.rawValue)"
                        let f = Metrics.beatF(ref: ft.ref, est: p.beats)
                        sums[key] = ((sums[key]?.0 ?? 0) + f, (sums[key]?.1 ?? 0) + 1)
                    }
                    var synthF = 0.0, synthN = 0, claims = 0, passes = 0
                    for (i, s) in synthetic.enumerated() {
                        let snaps = replayClock(synthPasses[i], floor: floor, span: span)
                        if s.rhythmic {
                            synthF += Metrics.beatF(ref: s.0.ref, est: playedBeats(snaps).beats); synthN += 1
                        } else {
                            for sn in snaps where sn.t > 5 {
                                passes += 1
                                if sn.s.bpm > 0 && sn.s.phaseConfidence >= 0.5 { claims += 1 }
                            }
                        }
                    }
                    rows.append(Row(name: String(format: "smooth %d tol %d floor %.2f span %.1f", smooth, tol, floor, span),
                                    f: sums.mapValues { $0.0 / Double($0.1) }, synthF: synthF / Double(max(1, synthN)),
                                    falseLock: Double(claims) / Double(max(1, passes)) * 100))
                }
            }
            print(String(format: "  smoothing %d, tolerance %d done (%.0f s)", smooth, tol, Date().timeIntervalSince(t0)))
        }
    }
    let keys = rows[0].f.keys.sorted()
    func mean(_ r: Row) -> Double { keys.map { r.f[$0] ?? 0 }.reduce(0, +) / Double(keys.count) }
    // The tracker as it shipped before build 915.
    let shipping = rows.first { $0.name == "smooth 0 tol 0 floor 0.20 span 0.3" }!
    print("\nrow                                   mean F  synth F  false lock %  " + keys.map { pad($0, 15) }.joined(separator: " "))
    func line(_ r: Row) -> String {
        String(format: "%@ %6.3f  %6.3f  %10.1f  ", pad(r.name, 38) as NSString, mean(r), r.synthF, r.falseLock)
            + keys.map { pad(String(format: "%.3f", r.f[$0] ?? 0), 15) }.joined(separator: " ")
    }
    print(line(shipping) + "   ← before build 915")
    // The best rows that lock on non-music no more than shipping does (+1 point)
    // and keep the synthetic songs within 0.02.
    let allowed = rows.filter { $0.falseLock <= shipping.falseLock + 1 && $0.synthF >= shipping.synthF - 0.02 }
    for r in allowed.sorted(by: { mean($0) > mean($1) }).prefix(15) { print(line(r)) }
    // Timing: the signed error of every played beat within ±70 ms of a real
    // one, for shipping and the candidates (negative = the light is early).
    func bias(_ tuning: BeatTrackerTuning, floor: Double, span: Double) -> String {
        var errs: [Double] = []
        var fsum = 0.0
        for ft in real where ft.condition == .line {
            let played = playedBeats(replayClock(trackerPasses(ft.frames, tuning: tuning), floor: floor, span: span)).beats
            fsum += Metrics.beatF(ref: ft.ref, est: played)
            var j = 0
            for b in played where b >= 5 {
                while j + 1 < ft.ref.count && abs(ft.ref[j + 1] - b) <= abs(ft.ref[j] - b) { j += 1 }
                if j < ft.ref.count, abs(ft.ref[j] - b) <= 0.07 { errs.append((b - ft.ref[j]) * 1000) }
            }
        }
        let sorted = errs.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return String(format: "line F %.3f · %d beats · error median %+.1f ms, mean %+.1f, |p90| %.1f",
                      fsum / Double(real.filter { $0.condition == .line }.count), errs.count, pct(0.5),
                      errs.reduce(0, +) / Double(max(1, errs.count)), errs.map { abs($0) }.sorted()[min(errs.count - 1, Int(Double(errs.count) * 0.9))])
    }
    print("\ntiming (real songs, line):")
    print("  before 915                  " + bias(.raw, floor: 0.2, span: 0.3))
    for smooth in [2, 4, 6] {
        for phase in [true, false] {
            var t = BeatTrackerTuning.raw
            t.smoothFrames = smooth
            t.smoothPhase = phase
            print(String(format: "  smooth %d, phase %@  ", smooth, (phase ? "smoothed" : "raw     ") as NSString) + bias(t, floor: 0.16, span: 0.3))
        }
    }
    print("\nbest regardless of false locks:")
    for r in rows.sorted(by: { mean($0) > mean($1) }).prefix(5) { print(line(r)) }
}
