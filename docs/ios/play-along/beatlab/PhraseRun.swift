// PhraseRun.swift — build 920: does the app know where the phrases are?
//
//   run.sh -phrase [-n 20]
//
// The whole live chain, causally: OnsetFrameAnalyzer (+ drum and activity
// lanes), BeatTracker and BeatClock every 0.5 s, and the app's
// SongStructureTracker on the same pass. Clean and through the lab's rooms.
//
//  • Synthetic arrangements (ArrangementSynth): exact phrase lines (every
//    section start, and every 8 bars inside longer sections). "Called ahead"
//    = one bar before a section starts, the tracker's next phrase start was
//    within ±1 beat of it. "Grid right" = the share of bar lines (from 16
//    bars after the clock locked) at which the predicted next phrase start
//    is within ±1 beat of a true phrase line.
//  • BabySlakh: the truth is where the INSTRUMENTATION changes — a bar whose
//    set of playing stems (each within 20 dB of its own loudest bar) differs
//    from the bar before and holds for the next. Not every phrase changes
//    instruments and not every change starts a phrase, so this is a proxy.
//    Called ahead as above; precision = the share of phrase starts the
//    tracker passed (confidence ≥ 0.3) that land on a change.
// Chance, for an 8-bar grid placed at random: called ahead ≈ 1/8 = 0.125.

import Foundation

/// One run of the live chain: the structure published after every pass.
@MainActor
func structureTimeline(_ x: [Float], fs: Double) -> [(t: Double, s: SongStructure, beat: BeatSnapshot)] {
    let clock = BeatClock(); clock.clear()
    let analyzer = OnsetFrameAnalyzer()
    let tracker = BeatTracker()
    let song = SongStructureTracker()
    let hop = 1024
    var nextPass = 0.5
    var out: [(Double, SongStructure, BeatSnapshot)] = []
    x.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= x.count {
            let start = Double(k * hop) / fs
            let arrival = start + Double(hop) / fs + 0.004
            analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: fs, bufferStart: start)
            if arrival >= nextPass {
                nextPass += 0.5
                let frames = analyzer.snapshot(seconds: BeatTracker.windowSeconds + 2)
                if let o = tracker.update(frames) { clock.ingest(observation: o) } else { clock.noteNoBeat(at: arrival) }
                let beat = BeatClock.snapshot()
                out.append((arrival, song.update(frames, beat: beat), beat))
            }
            k += 1
        }
    }
    return out
}

@MainActor
func phraseReport(_ args: [String]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let perSet = value("-n").flatMap(Int.init) ?? 20
    let fs = 48_000.0
    let manifest = try? Corpus.loadManifest()
    func loadRIRs(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: fs) } }
    }
    let rirs = loadRIRs(manifest?.rirs), halls = loadRIRs(manifest?.hallRirs)
    struct Tally { var lines = 0, called = 0, calledSure = 0, gridBars = 0, gridRight = 0, passed = 0, passedOnChange = 0
                   var lockBars: [Double] = [] }
    var tally: [String: Tally] = [:]
    let started = Date()

    /// The latest snapshot at or before `t`.
    func at(_ tl: [(t: Double, s: SongStructure, beat: BeatSnapshot)], _ t: Double) -> SongStructure? {
        var lo = 0, hi = tl.count - 1, best: Int? = nil
        while lo <= hi { let m = (lo + hi) / 2; if tl[m].t <= t { best = m; lo = m + 1 } else { hi = m - 1 } }
        return best.map { tl[$0].s }
    }

    func score(_ key: String, tl: [(t: Double, s: SongStructure, beat: BeatSnapshot)], lines: [Double],
               changes: [Double], barLines: [Double], beatSeconds: Double) {
        var t = tally[key, default: Tally()]
        // When the song's phrase grid could first be known: 16 bars after lock.
        guard let lock = tl.first(where: { $0.s.hasSong }) else { tally[key] = t; return }
        let barSec = 4 * beatSeconds
        let ready = lock.t + 16 * barSec
        t.lockBars.append((lock.t - (barLines.first ?? 0)) / barSec)
        for line in changes where line > ready + barSec {
            guard let s = at(tl, line - barSec), s.hasSong else { continue }
            t.lines += 1
            let predicted = s.nextPhraseStart(after: line - 0.6 * barSec)
            if abs(predicted - line) <= beatSeconds {
                t.called += 1
                if s.phraseConfidence >= 0.3 { t.calledSure += 1 }
            }
        }
        for bl in barLines where bl > ready {
            guard let s = at(tl, bl - 0.6 * barSec), s.hasSong else { continue }
            t.gridBars += 1
            let predicted = s.nextPhraseStart(after: bl - 0.6 * barSec)
            if lines.contains(where: { abs($0 - predicted) <= beatSeconds }) { t.gridRight += 1 }
        }
        // Phrase starts the tracker passed with some confidence: on a change?
        var lastCounted = -Double.infinity
        for (i, p) in tl.enumerated() where i > 0 && p.t > ready && p.s.hasSong {
            let prev = tl[i - 1].s
            guard prev.hasSong, prev.phraseConfidence >= 0.3 else { continue }
            let lineTime = prev.nextPhraseStart(after: tl[i - 1].t)
            guard lineTime <= p.t, lineTime > lastCounted + barSec else { continue }
            lastCounted = lineTime
            t.passed += 1
            if changes.contains(where: { abs($0 - lineTime) <= beatSeconds }) { t.passedOnChange += 1 }
        }
        tally[key] = t
    }

    var synthBars: [String: (on: Int, all: Int)] = [:]
    // ── Synthetic arrangements ──
    for song in ArrangementSynth.songs {
        let r = ArrangementSynth.render(song, fs: fs)
        let seed = fnv1a(song.name)
        // True phrase lines: every section start, and every 8 bars within one.
        var lines: [Double] = []
        for (i, s) in r.sections.enumerated() {
            let endBar = i + 1 < r.sections.count ? r.sections[i + 1].bar : r.barLines.count
            var b = s.bar
            while b < endBar { lines.append(r.firstDownbeat + Double(b) * r.barSeconds); b += 8 }
        }
        let starts = r.sections.dropFirst().map(\.time)
        for condition in Condition.allCases {
            let pool = condition == .hall ? halls : rirs
            let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
            let x = RoomSim.apply(condition, to: r.samples, fs: fs, rir: rir, seed: seed)
            let tl = structureTimeline(x, fs: fs)
            score("synth \(condition.rawValue)", tl: tl, lines: lines, changes: Array(starts), barLines: r.barLines,
                  beatSeconds: 60 / r.bpm)
            var seen = Set<Double>(), onDown = 0, total = 0
            for p in tl where p.s.hasSong && !seen.contains(p.s.currentBarStart) {
                seen.insert(p.s.currentBarStart); total += 1
                if (r.barLines.map { abs($0 - p.s.currentBarStart) }.min() ?? 1) <= 0.07 { onDown += 1 }
            }
            synthBars[condition.rawValue, default: (0, 0)].on += onDown
            synthBars[condition.rawValue, default: (0, 0)].all += total
        }
    }

    var oracle: [String: (on: Int, all: Int)] = [:]
    var barDiag: [String: (onDown: Int, onBeat: Int, total: Int, tempo: Int, passes: Int)] = [:]
    // ── BabySlakh: instrumentation changes ──
    if let manifest, !args.contains("-synthonly") {
        let all = manifest.tracks.filter { $0.set == "slakh" }
        for track in all.prefix(perSet) {
            guard let audio = try? Corpus.loadAudio(Corpus.url(track.audio)),
                  let beatsPath = track.beats, let beats = try? Corpus.readBeats(Corpus.url(beatsPath)) else { continue }
            let downbeats = beats.filter { $0.beatInBar == 1 }.map(\.time)
            guard downbeats.count > 24 else { continue }
            let beatSeconds = (downbeats.last! - downbeats.first!) / Double(downbeats.count - 1) / 4
            // Every rendered stem's level per bar.
            let dir = Corpus.url(track.audio).deletingLastPathComponent().appendingPathComponent("stems")
            let stems = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            var active: [[Bool]] = Array(repeating: [], count: downbeats.count - 1)
            for name in stems {
                guard let x = try? Corpus.loadAudio(dir.appendingPathComponent(name), fs: 16_000) else { continue }
                let levels: [Float] = (0..<(downbeats.count - 1)).map { b in
                    let lo = Int(downbeats[b] * 16_000), hi = min(x.count, Int(downbeats[b + 1] * 16_000))
                    guard hi > lo else { return -120 }
                    var s: Float = 0; for i in lo..<hi { s += x[i] * x[i] }
                    return 10 * log10(max(s / Float(hi - lo), 1e-14))
                }
                let sorted = levels.sorted()
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                for b in levels.indices { active[b].append(levels[b] > max(p95 - 20, -60)) }
            }
            var changes: [Double] = []
            for b in 1..<(active.count - 1) where active[b] != active[b - 1] && active[b] == active[b + 1] {
                changes.append(downbeats[b])
            }
            // Diagnostics: is the truth on an 8-bar (or 4-bar) grid at all?
            // The best grid in hindsight, per song.
            let changeBars = (1..<(active.count - 1)).filter { active[$0] != active[$0 - 1] && active[$0] == active[$0 + 1] }
            for period in [4, 8] {
                let best = (0..<period).map { o in changeBars.filter { ($0 - o) % period == 0 }.count }.max() ?? 0
                oracle["\(period)", default: (0, 0)].on += best
                oracle["\(period)", default: (0, 0)].all += changeBars.count
            }
            let seed = fnv1a(track.id)
            for condition in Condition.allCases {
                let pool = condition == .hall ? halls : rirs
                let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
                let x = RoomSim.apply(condition, to: audio, fs: fs, rir: rir, seed: seed)
                let tl = structureTimeline(x, fs: fs)
                // The clock's bar lines (as the tracker counted them) vs the true downbeats.
                var seen = Set<Double>(), onDownbeat = 0, onBeat = 0, total = 0, tempoRight = 0, passes = 0
                for p in tl where p.s.hasSong {
                    passes += 1
                    if abs(p.beat.bpm * beatSeconds / 60 - 1) < 0.04 { tempoRight += 1 }
                    guard !seen.contains(p.s.currentBarStart) else { continue }
                    seen.insert(p.s.currentBarStart); total += 1
                    let d = downbeats.map { abs($0 - p.s.currentBarStart) }.min() ?? 1
                    if d <= 0.07 { onDownbeat += 1 }
                    let nearestBeat = beats.map { abs($0.time - p.s.currentBarStart) }.min() ?? 1
                    if nearestBeat <= 0.07 { onBeat += 1 }
                }
                var dg = barDiag["\(condition.rawValue)", default: (0, 0, 0, 0, 0)]
                dg.onDown += onDownbeat; dg.onBeat += onBeat; dg.total += total; dg.tempo += tempoRight; dg.passes += passes
                barDiag["\(condition.rawValue)"] = dg
                // Phrase lines aren't known for real songs: "grid right" uses the changes.
                score("slakh \(condition.rawValue)", tl: tl, lines: changes, changes: changes,
                      barLines: Array(downbeats.dropLast()), beatSeconds: beatSeconds)
            }
        }
    }

    for (period, o) in oracle.sorted(by: { $0.key < $1.key }) {
        print(String(format: "BabySlakh changes on the best %@-bar grid in hindsight (per song): %.2f of %d", period, Double(o.on) / Double(max(1, o.all)), o.all))
    }
    for (cond, d) in synthBars.sorted(by: { $0.key < $1.key }) {
        print(String(format: "Synthetic %@: the clock's bar lines on a true downbeat %.2f (of %d)", cond, Double(d.on) / Double(max(1, d.all)), d.all))
    }
    for (cond, d) in barDiag.sorted(by: { $0.key < $1.key }) {
        print(String(format: "BabySlakh %@: the clock's tempo right %.2f of passes; its bar lines on a true downbeat %.2f, on any beat %.2f (of %d)",
                     cond, Double(d.tempo) / Double(max(1, d.passes)), Double(d.onDown) / Double(max(1, d.total)),
                     Double(d.onBeat) / Double(max(1, d.total)), d.total))
    }
    print(String(format: "phrase: %d synthetic arrangements + BabySlakh (≤ %d), line/room/speaker/hall, %.0f s",
                 ArrangementSynth.songs.count, perSet, Date().timeIntervalSince(started)))
    print("set/cond        section starts  called ahead  (sure ≥0.3)   grid right   passed phrase starts on a change   lock (bars in)")
    for key in tally.keys.sorted() {
        let t = tally[key]!
        let lock = t.lockBars.sorted()
        print(String(format: "%@ %6d %12.2f %12.2f %13.2f %15.2f (%d)  %14.1f",
                     pad(key, 15), t.lines, Double(t.called) / Double(max(1, t.lines)),
                     Double(t.calledSure) / Double(max(1, t.lines)), Double(t.gridRight) / Double(max(1, t.gridBars)),
                     Double(t.passedOnChange) / Double(max(1, t.passed)), t.passed,
                     lock.isEmpty ? Double.nan : lock[lock.count / 2]))
    }
}
