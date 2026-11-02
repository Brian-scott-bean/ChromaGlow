// DrumRun.swift — how well the app hears drums, on recordings with every
// kick, snare and hi-hat annotated (Groove MIDI, BabySlakh).
//
//   run.sh -drums                         every set with drum annotations
//   run.sh -drums -set gmd -cond room     one set, one condition
//
// Each detector is scored per kind: recall = the share of that drum's hits it
// fired on within ±50 ms; precision = the share of its firings that land on
// that drum. Today's one "hit" (AudioFeatureExtractor's onset, the Hit
// source) is scored against every kind, since it was never meant to tell
// them apart. A detector is any function from audio to (time, kind) firings.

import Foundation

typealias DrumDetector = (_ samples: [Float], _ fs: Double) -> [DrumHit]

/// Today's onset: the legacy extractor on 1024-frame hops (MicrophoneHopRelay),
/// stamped at the end of each hop as the live path stamps it.
func legacyOnsets(_ x: [Float], fs: Double) -> [DrumHit] {
    let extractor = AudioFeatureExtractor()
    let hop = 1024
    var out: [DrumHit] = []
    var last = 0.0
    x.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= x.count {
            let end = Double((k + 1) * hop) / fs
            if let f = extractor.process(data: p.baseAddress! + k * hop, frameCount: hop, sampleRate: Float(fs),
                                         hostTime: end, captureTime: end),
               f.isOnset, f.lastOnsetAt != last {
                last = f.lastOnsetAt
                out.append(DrumHit(time: f.lastOnsetAt, kind: "any"))
            }
            k += 1
        }
    }
    return out
}

struct DrumScore { var hits = 0; var ref = 0; var fired = 0; var matched = 0 }

func drumReport(_ args: [String], detectors: [(name: String, run: DrumDetector)]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let manifest = try? Corpus.loadManifest() else {
        print("No corpus manifest at \(Corpus.manifestURL.path) — run `run.sh -import` first"); return
    }
    let sets = value("-set").map { Set($0.split(separator: ",").map(String.init)) }
    let conditions: [Condition] = value("-cond").map { $0.split(separator: ",").compactMap { Condition(rawValue: String($0)) } }
        ?? Condition.allCases
    let limit = value("-limit").flatMap(Int.init) ?? .max
    let window = 0.05
    let kinds = ["kick", "snare", "hat"]
    let tracks = manifest.tracks.filter { $0.drums != nil && (sets?.contains($0.set) ?? true) }.prefix(limit)
    func load(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: 48_000) } }
    }
    let rirs = load(manifest.rirs), halls = load(manifest.hallRirs)
    print("drums: \(tracks.count) tracks, conditions \(conditions.map(\.rawValue).joined(separator: ",")), \(rirs.count) home-like rooms, \(halls.count) halls, ±\(Int(window * 1000)) ms")
    // [set|cond|detector|kind] → score
    var table: [String: DrumScore] = [:]
    let started = Date()
    for track in tracks {
        guard let drumsPath = track.drums, let ref = try? Corpus.readDrums(Corpus.url(drumsPath)),
              let audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
        let seed = fnv1a(track.id)
        for condition in conditions {
            let pool = condition == .hall ? halls : rirs
            let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
            let x = RoomSim.apply(condition, to: audio, fs: 48_000, rir: rir, seed: seed)
            for d in detectors {
                let fired = d.run(x, 48_000)
                for kind in kinds {
                    // Hits to find: this drum's strokes, ghost notes aside
                    // (velocity < 40, when known) — a light shouldn't jump on
                    // those. A firing on a ghost note still counts as landing
                    // on the drum.
                    let all = ref.filter { $0.kind == kind }
                    let r = all.filter { $0.velocity == 0 || $0.velocity >= 40 }.map(\.time)
                    guard !r.isEmpty else { continue }
                    // A detector that names kinds is scored on its own firings
                    // of that kind; one that doesn't, on all of them.
                    let mine = fired.contains { $0.kind != "any" } ? fired.filter { $0.kind == kind } : fired
                    let e = mine.map(\.time)
                    let key = "\(track.set)|\(condition.rawValue)|\(d.name)|\(kind)"
                    var s = table[key, default: DrumScore()]
                    s.ref += r.count
                    s.hits += Metrics.matchCount(r, e, window: window)
                    s.fired += e.count
                    // Precision: firings that land on this drum's family (ghosts
                    // included; a ride or crash for the hi-hat lane).
                    let family = ref.filter { laneFamily[kind]!.contains($0.kind) }.map(\.time).sorted()
                    s.matched += Metrics.matchCount(e, family, window: window)
                    table[key] = s
                }
            }
        }
    }
    print("")
    print("set          cond     detector        kind    recall  precision     F   (hits / annotated, firings)")
    for key in table.keys.sorted() {
        let p = key.split(separator: "|").map(String.init)
        let s = table[key]!
        let recall = s.ref > 0 ? Double(s.hits) / Double(s.ref) : 0
        let precision = s.fired > 0 ? Double(s.matched) / Double(s.fired) : 0
        let f = recall + precision > 0 ? 2 * recall * precision / (recall + precision) : 0
        print(String(format: "%@ %@ %@ %@ %6.3f %10.3f %6.3f   (%d / %d, %d)",
                     pad(p[0], 12) as NSString, pad(p[1], 8) as NSString, pad(p[2], 15) as NSString,
                     pad(p[3], 6) as NSString, recall, precision, f, s.hits, s.ref, s.fired))
    }
    print(String(format: "(%.0f s)", Date().timeIntervalSince(started)))
}

/// The app's drum lanes (build 915): OnsetFrameAnalyzer with DrumLanes inside,
/// fed 1024-frame hops as the microphone delivers them; each lane's firings
/// read back from the frame ring.
func laneDetector(_ tuning: DrumLaneTuning = .standard) -> DrumDetector {
    return { x, fs in
        let analyzer = OnsetFrameAnalyzer(drumTuning: tuning)
        let hop = 1024
        var out: [DrumHit] = []
        var lastTime = -Double.infinity
        x.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * hop <= x.count {
                analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: fs, bufferStart: Double(k * hop) / fs)
                if k % 8 == 7 || (k + 2) * hop > x.count {
                    // A held hit is marked back on its onset frame: read only
                    // frames older than the longest hold (the end flushes all).
                    let f = analyzer.snapshot(seconds: 0.5)
                    let settled = (k + 2) * hop > x.count ? Double.infinity : (f.times.last ?? 0) - DrumLanes.settleSeconds
                    for i in 0..<f.count where f.times[i] > lastTime && f.times[i] <= settled {
                        if f.kick[i] > 0 { out.append(DrumHit(time: f.times[i], kind: "kick")) }
                        if f.snare[i] > 0 { out.append(DrumHit(time: f.times[i], kind: "snare")) }
                        if f.hat[i] > 0 { out.append(DrumHit(time: f.times[i], kind: "hat")) }
                        lastTime = f.times[i]
                    }
                }
                k += 1
            }
        }
        return out
    }
}

// MARK: - Tuning (run.sh -drumtune)

/// Band levels of every analysis frame of one recording (the analyzer's own).
struct LevelTrack {
    var set: String
    var condition: Condition
    var times: [Double] = []
    var levels: [Float] = []      // bandCount per frame
    var ref: [DrumHit] = []
}

func recordLevels(_ x: [Float], fs: Double) -> (times: [Double], levels: [Float]) {
    let analyzer = OnsetFrameAnalyzer()
    let hop = 1024
    var times: [Double] = [], levels: [Float] = []
    var lastTime = -Double.infinity
    x.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= x.count {
            analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: fs, bufferStart: Double(k * hop) / fs)
            if k % 8 == 7 || (k + 2) * hop > x.count {
                let f = analyzer.snapshot(seconds: 0.5)
                for i in 0..<f.count where f.times[i] > lastTime {
                    times.append(f.times[i])
                    levels.append(contentsOf: f.bands[(i * f.bandCount)..<((i + 1) * f.bandCount)])
                    lastTime = f.times[i]
                }
            }
            k += 1
        }
    }
    return (times, levels)
}

/// Replays DrumLanes over recorded levels: (kind → firing times).
func replay(_ t: LevelTrack, tuning: DrumLaneTuning) -> [String: [Double]] {
    let n = OnsetFrameAnalyzer.bandCount
    let lanes = DrumLanes(bandCount: n, tuning: tuning)
    var out: [String: [Double]] = ["kick": [], "snare": [], "hat": []]
    t.levels.withUnsafeBufferPointer { p in
        for i in 0..<t.times.count {
            let h = lanes.process(levels: UnsafeBufferPointer(rebasing: p[(i * n)..<((i + 1) * n)]), time: t.times[i],
                                  frameRate: 100)
            if h.kick > 0 { out["kick"]!.append(lanes.lastKickTime) }
            if h.snare > 0 { out["snare"]!.append(lanes.lastSnareTime) }
            if h.hat > 0 { out["hat"]!.append(t.times[i]) }
        }
    }
    return out
}

/// What each lane may land on and still be right: the hi-hat lane is the
/// band's shimmer, so a ride or crash counts; a rim click counts as snare.
let laneFamily: [String: Set<String>] = ["kick": ["kick"], "snare": ["snare", "sidestick"],
                                         "hat": ["hat", "hatpedal", "cymbal"]]

/// F per kind over a set of recordings (recall on strokes ≥ velocity 40,
/// precision against every stroke of that drum's family), ±50 ms.
func laneF(_ tracks: [LevelTrack], tuning: DrumLaneTuning) -> [String: (r: Double, p: Double, f: Double)] {
    var hits: [String: Int] = [:], refs: [String: Int] = [:], fired: [String: Int] = [:], matched: [String: Int] = [:]
    for t in tracks {
        let est = replay(t, tuning: tuning)
        for kind in ["kick", "snare", "hat"] {
            let all = t.ref.filter { $0.kind == kind }
            let r = all.filter { $0.velocity == 0 || $0.velocity >= 40 }.map(\.time)
            guard !r.isEmpty else { continue }
            let e = est[kind]!
            let family = t.ref.filter { laneFamily[kind]!.contains($0.kind) }.map(\.time).sorted()
            hits[kind, default: 0] += Metrics.matchCount(r, e, window: 0.05)
            refs[kind, default: 0] += r.count
            fired[kind, default: 0] += e.count
            matched[kind, default: 0] += Metrics.matchCount(e, family, window: 0.05)
        }
    }
    var out: [String: (Double, Double, Double)] = [:]
    for kind in refs.keys {
        let r = Double(hits[kind]!) / Double(max(1, refs[kind]!))
        let p = Double(matched[kind]!) / Double(max(1, fired[kind]!))
        out[kind] = (r, p, r + p > 0 ? 2 * r * p / (r + p) : 0)
    }
    return out
}

/// The tuning set: 24 Groove MIDI takes and 20 BabySlakh mixes (every n-th
/// track), line and through a measured home-like room, as band levels.
func recordTuneSet() -> [LevelTrack]? {
    guard let manifest = try? Corpus.loadManifest() else { print("no manifest"); return nil }
    let perSet = 24
    var chosen: [CorpusTrack] = []
    for set in ["gmd", "slakh"] {
        let all = manifest.tracks.filter { $0.set == set && $0.drums != nil }
        // Every n-th track: spread over drummers, styles and tempos.
        let step = max(1, all.count / perSet)
        chosen += stride(from: 0, to: all.count, by: step).prefix(perSet).map { all[$0] }
    }
    func load(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: 48_000) } }
    }
    let rirs = load(manifest.rirs)
    var tracks: [LevelTrack] = []
    let t0 = Date()
    for track in chosen {
        guard let ref = try? Corpus.readDrums(Corpus.url(track.drums!)),
              let audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
        let seed = fnv1a(track.id)
        for condition in [Condition.line, .room] {
            let rir = rirs.isEmpty ? nil : rirs[Int(seed % UInt64(rirs.count))]
            let x = RoomSim.apply(condition, to: audio, fs: 48_000, rir: rir, seed: seed)
            let rec = recordLevels(x, fs: 48_000)
            tracks.append(LevelTrack(set: track.set, condition: condition, times: rec.times, levels: rec.levels, ref: ref))
        }
    }
    print(String(format: "recorded %d recordings (%d tracks × line, room) in %.0f s", tracks.count, chosen.count, Date().timeIntervalSince(t0)))
    return tracks
}

func drumTune(_ args: [String]) {
    guard let tracks = recordTuneSet() else { return }

    func show(_ name: String, _ t: DrumLaneTuning) {
        for set in ["gmd", "slakh"] {
            for cond in [Condition.line, .room] {
                let s = laneF(tracks.filter { $0.set == set && $0.condition == cond }, tuning: t)
                let parts = ["kick", "snare", "hat"].map { k in
                    s[k].map { String(format: "%@ R %.2f P %.2f F %.2f", k, $0.r, $0.p, $0.f) } ?? "\(k) —"
                }
                print("  \(pad(name, 26)) \(pad(set, 6)) \(pad(cond.rawValue, 5)) " + parts.joined(separator: " | "))
            }
        }
    }
    // Lanes are independent: each searches its own grid with the others fixed,
    // scored by mean F over the four set × condition groups.
    func meanF(_ t: DrumLaneTuning, _ kind: String) -> Double {
        var f = 0.0
        for set in ["gmd", "slakh"] { for cond in [Condition.line, .room] {
            f += (laneF(tracks.filter { $0.set == set && $0.condition == cond }, tuning: t)[kind]?.f ?? 0) / 4
        } }
        return f
    }
    var tuned = DrumLaneTuning.standard
    func search(_ kind: String, _ variants: [(String, (inout DrumLaneTuning) -> Void)]) {
        var best = (f: -1.0, name: "", apply: variants[0].1)
        for (name, apply) in variants {
            var t = tuned
            apply(&t)
            let f = meanF(t, kind)
            if f > best.f { best = (f, name, apply) }
        }
        best.apply(&tuned)
        print(String(format: "best %@: %@ (mean F %.3f of %d tried)", kind, best.name, best.f, variants.count))
    }
    func grid(_ ks: [Float], _ floors: [Float], _ set: @escaping (inout DrumLaneTuning, Float, Float) -> Void)
        -> [(String, (inout DrumLaneTuning) -> Void)] {
        ks.flatMap { k in floors.map { fl in (String(format: "k %.1f floor %.2f", k, fl), { (t: inout DrumLaneTuning) in set(&t, k, fl) }) } }
    }
    search("kick", grid([3, 4, 5, 6, 8, 10, 13], [0.6, 1, 1.5, 2, 3]) { $0.kickK = $1; $0.kickFloor = $2 })
    search("kick", [0...1, 0...2, 0...3, 1...2, 1...3].map { r in ("bands \(r)", { (t: inout DrumLaneTuning) in t.kickBands = r }) })
    search("kick", [0.06, 0.09, 0.12, 0.15].map { g in (String(format: "gap %.2f", g), { (t: inout DrumLaneTuning) in t.kickGap = g }) })
    search("snare", grid([0.5, 1, 1.5, 2, 3], [0.6, 1, 1.5, 2, 3, 4]) { $0.snareK = $1; $0.snareFloor = $2 })
    search("snare", [(3...5, 11...14), (2...4, 11...14), (3...6, 11...14), (3...5, 10...13), (3...5, 12...15), (2...5, 11...15)].map { b in
        ("body \(b.0) noise \(b.1)", { (t: inout DrumLaneTuning) in t.snareBodyBands = b.0; t.snareNoiseBands = b.1 })
    })
    search("snare", [0.06, 0.09, 0.12, 0.15].map { g in (String(format: "gap %.2f", g), { (t: inout DrumLaneTuning) in t.snareGap = g }) })
    search("hat", grid([1, 1.5, 2, 2.5, 3, 4], [0.03, 0.06, 0.1, 0.15, 0.3, 0.6]) { $0.hatK = $1; $0.hatFloor = $2 })
    search("hat", [14...17, 15...17, 16...17, 13...17].map { r in ("bands \(r)", { (t: inout DrumLaneTuning) in t.hatBands = r }) })
    search("hat", [0.03, 0.05, 0.07, 0.1].map { g in (String(format: "gap %.2f", g), { (t: inout DrumLaneTuning) in t.hatGap = g }) })
    search("kick", [Float(0), 0.1, 0.25, 0.5].map { c in (String(format: "click %.2f", c), { (t: inout DrumLaneTuning) in t.kickClick = c }) })
    search("kick", [0.75, 1.5, 3].map { m in (String(format: "memory %.2f s", m), { (t: inout DrumLaneTuning) in t.memory = m }) })
    // Kick vs bass: confirm by decay (the hit keeps its onset time).
    var confirm: [(String, (inout DrumLaneTuning) -> Void)] = [("no confirmation", { (t: inout DrumLaneTuning) in t.kickConfirmFrames = 0 })]
    for frames in [4, 6, 8, 12] {
        for decay: Float in [0.5, 1, 1.5, 2, 3] {
            confirm.append((String(format: "confirm %d frames, decay %.1f", frames, decay),
                            { (t: inout DrumLaneTuning) in t.kickConfirmFrames = frames; t.kickDecay = decay }))
        }
    }
    search("kick", confirm)
    search("kick", grid([2, 3, 4, 5, 6], [1, 1.5, 2]) { $0.kickK = $1; $0.kickFloor = $2 })
    search("snare", [false, true].map { v in ("veto on kick \(v)", { (t: inout DrumLaneTuning) in t.snareVetoOnKick = v }) })
    search("snare", grid([0.5, 1, 1.5], [1, 1.5, 2]) { $0.snareK = $1; $0.snareFloor = $2 })
    print("standard:")
    show("standard", .standard)
    print("tuned: \(tuned)")
    show("tuned", tuned)
}

extension DrumLaneTuning {
    /// The lanes as handed over mid-915 (pass 2 of `-drumtune`): no level
    /// gate, no snare veto or hold, hat k 2.5 floor 0.15.
    static var pass2: DrumLaneTuning {
        var t = DrumLaneTuning()
        t.kickLevelGate = .infinity; t.snareVetoOnKick = false; t.snareVetoWindow = 0; t.snareHoldFrames = 0
        t.hatK = 2.5; t.hatFloor = 0.15
        return t
    }
}

/// Kick vs bass (build 915): the lane's ways to tell a kick from a bass note,
/// on the tuning set — no wait, a loudness gate, and confirmation by decay
/// (which publishes the kick that many frames late).
func kickBass(_ args: [String]) {
    guard let tracks = recordTuneSet() else { return }
    let base = DrumLaneTuning.pass2
    var variants: [(String, DrumLaneTuning)] = [("pass 2 (as handed over)", base)]
    for gate: Float in [0.5, 1, 1.5, 2, 3, 4] {
        var t = base; t.kickLevelGate = gate
        variants.append((String(format: "level gate %.1f", gate), t))
    }
    for (frames, decay) in [(3, 0.5), (4, 0.5), (4, 1), (6, 1), (8, 1.5), (12, 2)] as [(Int, Float)] {
        var t = base; t.kickConfirmFrames = frames; t.kickDecay = decay; t.kickK = 6
        variants.append((String(format: "confirm %d decay %.1f (+%d ms)", frames, decay, frames * 10), t))
    }
    for gate: Float in [1, 2] {
        var t = base; t.kickLevelGate = gate; t.kickConfirmFrames = 4; t.kickDecay = 0.5
        variants.append((String(format: "gate %.1f + confirm 4 (+40 ms)", gate), t))
    }
    for gate: Float in [.infinity, 2, 3] {
        for window in [0, 0.03, 0.05] {
            var t = base; t.kickLevelGate = gate; t.snareVetoOnKick = true; t.snareVetoWindow = window
            variants.append((String(format: "gate %.1f + snare veto %.0f ms", gate, window * 1000), t))
        }
    }
    for gate: Float in [2, 3] {
        var t = base; t.kickLevelGate = gate; t.snareVetoOnKick = true; t.snareVetoWindow = 0.05
        t.snareHoldFrames = 1
        variants.append((String(format: "gate %.1f + veto 50 ms + hold 1", gate), t))
        t.hatK = 2; t.hatFloor = 0.3
        variants.append((String(format: "gate %.1f + veto 50 + hold 1 + hat 2/.3", gate), t))
    }
    variants.append(("standard (build 915)", .standard))
    print("variant                          set    cond   kick R    P     F  | snare R   P     F")
    for (name, t) in variants {
        var meanK = 0.0, meanS = 0.0
        for set in ["gmd", "slakh"] { for cond in [Condition.line, .room] {
            let s = laneF(tracks.filter { $0.set == set && $0.condition == cond }, tuning: t)
            if let k = s["kick"], let n = s["snare"] {
                meanK += k.f / 4; meanS += n.f / 4
                print(String(format: "%@ %@ %@ %.2f %.2f %.2f | %.2f %.2f %.2f", pad(name, 32), pad(set, 6),
                             pad(cond.rawValue, 5), k.r, k.p, k.f, n.r, n.p, n.f))
            }
        } }
        print(String(format: "%@ mean F kick %.3f snare %.3f", pad(name, 32), meanK, meanS))
    }
}
