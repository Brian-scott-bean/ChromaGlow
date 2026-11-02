// GrooveRun.swift — build 916: do drum looks light ON the drum?
//
// The whole live chain, causally, on annotated real recordings: the app's
// OnsetFrameAnalyzer (+ DrumLanes), BeatTracker and BeatClock passes every
// 0.5 s, and the GrooveMap fed from them, with the lights rendered every
// 20 ms for when they are SHOWN (the render lead, 0.1 s ahead). A light hit
// "starts" on the first rendered frame that carries it. Scored against the
// annotated kicks and snares: on time = within ±50 ms of a played stroke;
// the median error is over strokes matched within ±150 ms.
//
//   run.sh -groove [-n 60] [-sweep]
//
// "heard" = what the drum lanes hear (build 915 as it ships); "groove" = the
// same plus the groove map's predicted hits (GroovePattern.latestHit), for
// the standard tuning or (-sweep) several. "any-time P" = light hits within
// ±150 ms of a played stroke (late or not); "per stroke" = light hits per
// annotated stroke (> 1: extra or doubled flashes).

import Foundation

@MainActor
func grooveReport(_ args: [String]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let manifest = try? Corpus.loadManifest() else { print("no manifest — run.sh -import"); return }
    let perSet = value("-n").flatMap(Int.init) ?? 60
    let lead = 0.1, tick = 0.02, hop = 1024, fs = 48_000.0
    var chosen: [CorpusTrack] = []
    for set in ["gmd", "slakh"] {
        let all = manifest.tracks.filter { $0.set == set && $0.drums != nil }
        let step = max(1, all.count / perSet)
        chosen += stride(from: 0, to: all.count, by: step).prefix(perSet).map { all[$0] }
    }
    let rirs = (manifest.rirs ?? []).compactMap { rel in
        (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: fs) }
    }
    struct Tally { var refs = 0, fired = 0, onTime = 0, firedOnTime = 0, firedAnyTime = 0; var errors: [Double] = [] }
    var tally: [String: Tally] = [:]   // "set cond lane mode"
    var liveShare: [String: (live: Double, total: Double)] = [:]
    var variants: [(String, GrooveTuning)] = [("groove", .standard)]
    if args.contains("-sweep") {
        func v(_ name: String, _ change: (inout GrooveTuning) -> Void) { var t = GrooveTuning.standard; change(&t); variants.append((name, t)) }
        v("g win.08") { $0.matchWindow = 0.08 }
        v("g win.10") { $0.matchWindow = 0.10 }
        v("g w.62") { $0.minWeight = 0.62 }
        v("g w.70") { $0.minWeight = 0.7 }
        v("g miss1") { $0.missesToSuspend = 1 }
    }
    let started = Date()

    for track in chosen {
        guard let ref = try? Corpus.readDrums(Corpus.url(track.drums!)),
              let audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
        let seed = fnv1a(track.id)
        for condition in [Condition.line, .room] {
            let rir = rirs.isEmpty ? nil : rirs[Int(seed % UInt64(rirs.count))]
            let x = RoomSim.apply(condition, to: audio, fs: fs, rir: rir, seed: seed)
            let clock = BeatClock(); clock.clear()
            let analyzer = OnsetFrameAnalyzer()
            let tracker = BeatTracker()
            let maps = variants.map { GrooveMap(tuning: $0.1) }
            var patterns = [GroovePattern](repeating: .none, count: maps.count)
            var nextPass = 0.5
            var nextTick = 0.0
            // Per lane: last hit time seen by each mode, and the starts.
            var lastHeard: [Double] = [0, 0]
            var lastGroove = [[Double]](repeating: [0, 0], count: maps.count)
            var startsHeard: [[Double]] = [[], []]
            var startsGroove = [[[Double]]](repeating: [[], []], count: maps.count)
            var liveTicks = 0.0, ticks = 0.0
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
                        for m in maps.indices { patterns[m] = maps[m].update(frames, beat: BeatClock.snapshot()) }
                    }
                    // Frames rendered until the next hop arrives.
                    let beat = BeatClock.snapshot()
                    let drums = analyzer.drumHits()
                    while nextTick < arrival + Double(hop) / fs {
                        if nextTick >= arrival {
                            let shown = nextTick + lead
                            ticks += 1
                            if patterns[0].lastPredicted(.kick, at: shown, beat: beat) != nil { liveTicks += 1 }
                            for (lane, kind) in [DrumLanes.Kind.kick, .snare].enumerated() {
                                let heardAt = kind == .kick ? drums.kickAt : drums.snareAt
                                let strength = kind == .kick ? drums.kickStrength : drums.snareStrength
                                if heardAt > lastHeard[lane] { lastHeard[lane] = heardAt; startsHeard[lane].append(shown) }
                                for m in maps.indices {
                                    let g = patterns[m].latestHit(kind, heardAt: heardAt, heardStrength: strength, beat: beat, at: shown)
                                    if g.time > lastGroove[m][lane] { lastGroove[m][lane] = g.time; startsGroove[m][lane].append(shown) }
                                }
                            }
                        }
                        nextTick += tick
                    }
                    k += 1
                }
            }
            let key0 = "\(track.set) \(condition.rawValue)"
            liveShare[key0, default: (0, 0)].live += liveTicks
            liveShare[key0, default: (0, 0)].total += ticks
            for (lane, name) in ["kick", "snare"].enumerated() {
                let family: Set<String> = name == "kick" ? ["kick"] : ["snare", "sidestick"]
                let played = ref.filter { family.contains($0.kind) }.map(\.time).sorted()
                let strong = ref.filter { $0.kind == name && ($0.velocity == 0 || $0.velocity >= 40) }.map(\.time)
                for (mode, starts) in [("heard", startsHeard[lane])] + variants.indices.map({ (variants[$0].0, startsGroove[$0][lane]) }) {
                    var t = tally["\(key0) \(name) \(mode.replacingOccurrences(of: " ", with: "_"))", default: Tally()]
                    t.refs += strong.count
                    t.fired += starts.count
                    t.onTime += Metrics.matchCount(strong, starts, window: 0.05)
                    t.firedOnTime += Metrics.matchCount(starts, played, window: 0.05)
                    t.firedAnyTime += Metrics.matchCount(starts, played.map { $0 + 0.07 }, window: 0.08)
                    for r in strong {
                        if let s = starts.min(by: { abs($0 - r) < abs($1 - r) }), abs(s - r) <= 0.15 { t.errors.append(s - r) }
                    }
                    tally["\(key0) \(name) \(mode.replacingOccurrences(of: " ", with: "_"))"] = t
                }
            }
        }
    }
    print(String(format: "groove: %d tracks × line, room in %.0f s; lead %.0f ms, frames every %.0f ms",
                 chosen.count, Date().timeIntervalSince(started), lead * 1000, tick * 1000))
    print("set    cond  drum   mode          on-time R   P      F   median error  any-time P  per stroke  (strokes, light hits)  kick predicted")
    for key in tally.keys.sorted() {
        let t = tally[key]!
        let r = Double(t.onTime) / Double(max(1, t.refs)), p = Double(t.firedOnTime) / Double(max(1, t.fired))
        let f = r + p > 0 ? 2 * r * p / (r + p) : 0
        let e = t.errors.sorted()
        let parts = key.split(separator: " ").map(String.init)
        let share = liveShare["\(parts[0]) \(parts[1])"].map { $0.live / max(1, $0.total) } ?? 0
        print(String(format: "%@ %@ %@ %@ %8.2f %6.2f %6.2f   %+7.0f ms   %8.2f   %9.2f    (%d, %d)   %@",
                     pad(parts[0], 6), pad(parts[1], 5), pad(parts[2], 6), pad(parts[3], 12), r, p, f,
                     e.isEmpty ? Double.nan : e[e.count / 2] * 1000,
                     Double(t.firedAnyTime) / Double(max(1, t.fired)), Double(t.fired) / Double(max(1, t.refs)), t.refs, t.fired,
                     parts[2] == "kick" && parts[3] == "groove" ? String(format: "%.0f %% of frames", share * 100) : ""))
    }
}
