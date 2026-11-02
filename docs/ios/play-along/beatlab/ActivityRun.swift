// ActivityRun.swift — build 919: is a bass line playing, are drums playing?
//
//   run.sh -activity [-n 20] [-set slakh,gmd,guitarset,candombe]
//
// The app's OnsetFrameAnalyzer (with DrumLanes and ActivityLanes inside), fed
// 1024-frame hops as the microphone delivers them, causally, clean and through
// the lab's rooms. Each lane's value is read at the END of every 1 s window
// (hop 0.5 s) and scored against what played in that window:
//  • BabySlakh: the stems. An instrument plays when its stem (bass stems:
//    `inst_class: Bass`; drum stems: `is_drum: true`; keyed on stems/SNN.wav
//    existing — `audio_rendered` in metadata.yaml is false everywhere and
//    wrong) is within 20 dB of its own loudest 1 s window and above -60 dBFS.
//    Windows where the whole mix is below -50 dBFS (song ends) are left out.
//  • Groove MIDI and Candombe: drums, never a bass line. GuitarSet: a guitar
//    alone — neither.
// "on" = the lane ≥ 0.5. Balanced accuracy = the mean of the share of
// playing windows read as on and of silent-instrument windows read as off.
// Per-song AUC = how well the lane orders one song's windows (does it dip
// when the bass drops out?), averaged over songs with both. ActivityTuning's
// centres were tuned on the songs whose id hashes even; "held out" rows use
// only the others. "Notice" = seconds from a change in the stems (≥ 3 s of
// the other state before and after) until the lane crosses 0.5, median.

import Foundation

private struct ActivityTruth { var t: Double; var bass: Bool; var drums: Bool }

/// The bass and drum stems of a BabySlakh track, from its metadata.yaml.
func slakhStems(_ dir: URL) -> (bass: [URL], drums: [URL]) {
    let yaml = (try? String(contentsOf: dir.appendingPathComponent("metadata.yaml"), encoding: .utf8)) ?? ""
    var bass: [URL] = [], drums: [URL] = []
    var current = "", cls = "", isDrum = false
    func flush() {
        guard !current.isEmpty else { return }
        let u = dir.appendingPathComponent("stems/\(current).wav")
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        if cls == "Bass" { bass.append(u) }
        if isDrum { drums.append(u) }
    }
    for line in yaml.split(separator: "\n").map(String.init) {
        if line.hasPrefix("  S"), line.hasSuffix(":") {
            flush(); current = String(line.dropFirst(2).dropLast()); cls = ""; isDrum = false
        } else if line.contains("inst_class:") {
            cls = line.components(separatedBy: "inst_class: ").last ?? ""
        } else if line.contains("is_drum:") {
            isDrum = line.contains("true")
        }
    }
    flush()
    return (bass, drums)
}

/// AUC by Mann–Whitney: the chance a playing window scores above a silent one.
func rankAUC(_ pos: [Float], _ neg: [Float]) -> Double {
    guard !pos.isEmpty, !neg.isEmpty else { return .nan }
    var all = pos.map { ($0, true) } + neg.map { ($0, false) }
    all.sort { $0.0 < $1.0 }
    var rankSum = 0.0, i = 0
    while i < all.count {
        var j = i
        while j + 1 < all.count && all[j + 1].0 == all[i].0 { j += 1 }
        let r = Double(i + j) / 2 + 1
        for k in i...j where all[k].1 { rankSum += r }
        i = j + 1
    }
    let np = Double(pos.count), nn = Double(neg.count)
    return (rankSum - np * (np + 1) / 2) / (np * nn)
}

/// The analyzer's activity per frame, run causally over 1024-frame hops.
func recordActivity(_ x: [Float], fs: Double, tuning: ActivityTuning = .standard)
    -> (times: [Double], bass: [Float], drums: [Float]) {
    let analyzer = OnsetFrameAnalyzer(activityTuning: tuning)
    let hop = 1024
    var times: [Double] = [], bass: [Float] = [], drums: [Float] = []
    var lastTime = -Double.infinity
    x.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= x.count {
            analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: fs, bufferStart: Double(k * hop) / fs)
            if k % 8 == 7 || (k + 2) * hop > x.count {
                let f = analyzer.snapshot(seconds: 0.5)
                for i in 0..<f.count where f.times[i] > lastTime {
                    times.append(f.times[i]); bass.append(f.bassActivity[i]); drums.append(f.drumActivity[i])
                    lastTime = f.times[i]
                }
            }
            k += 1
        }
    }
    return (times, bass, drums)
}

func activityReport(_ args: [String]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let manifest = try? Corpus.loadManifest() else { print("no manifest — run.sh -import"); return }
    let perSet = value("-n").flatMap(Int.init) ?? 20
    let sets = value("-set").map { $0.split(separator: ",").map(String.init) } ?? ["slakh", "gmd", "guitarset", "candombe"]
    let fs = 48_000.0
    func loadRIRs(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: fs) } }
    }
    let rirs = loadRIRs(manifest.rirs), halls = loadRIRs(manifest.hallRirs)
    func heldOut(_ id: String) -> Bool { fnv1a(id) % 2 == 1 }

    struct Window { var set: String; var cond: String; var song: String; var bass: Float; var drums: Float; var truth: ActivityTruth }
    var windows: [Window] = []
    var notice: [String: [Double]] = [:]          // "lane cond in|out" → seconds
    let started = Date()

    for set in sets {
        let all = manifest.tracks.filter { $0.set == set }
        let step = max(1, all.count / perSet)
        let chosen = stride(from: 0, to: all.count, by: step).prefix(perSet).map { all[$0] }
        for track in chosen {
            guard var audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
            if set != "slakh", audio.count > Int(120 * fs) { audio = Array(audio.prefix(Int(120 * fs))) }
            let duration = Double(audio.count) / fs
            // Truth windows (end times) — from the stems for BabySlakh.
            var truth: [ActivityTruth] = []
            var silent: [Bool] = []
            if set == "slakh" {
                let dir = Corpus.url(track.audio).deletingLastPathComponent()
                let stems = slakhStems(dir)
                func sum(_ urls: [URL]) -> [Float] {
                    var acc = [Float](repeating: 0, count: Int(duration * 16_000) + 16)
                    for u in urls { if let x = try? Corpus.loadAudio(u, fs: 16_000) { for i in 0..<min(acc.count, x.count) { acc[i] += x[i] } } }
                    return acc
                }
                let b = sum(stems.bass), d = sum(stems.drums)
                let mix = (try? Corpus.loadAudio(Corpus.url(track.audio), fs: 16_000)) ?? []
                func db(_ x: [Float], _ end: Double) -> Float {
                    let hi = min(x.count, Int(end * 16_000)), lo = max(0, hi - 16_000)
                    guard hi > lo else { return -120 }
                    var s: Float = 0; for i in lo..<hi { s += x[i] * x[i] }
                    return 10 * log10(max(s / Float(hi - lo), 1e-14))
                }
                let ends = Array(stride(from: 1.0, through: duration, by: 0.5))
                let wb = ends.map { db(b, $0) }, wd = ends.map { db(d, $0) }, wm = ends.map { db(mix, $0) }
                func p95(_ a: [Float]) -> Float { let s = a.sorted(); return s.isEmpty ? -120 : s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
                let pb = p95(wb), pd = p95(wd)
                for (k, t) in ends.enumerated() {
                    truth.append(ActivityTruth(t: t, bass: wb[k] > max(pb - 20, -60), drums: wd[k] > max(pd - 20, -60)))
                    silent.append(wm[k] < -50)
                }
            } else {
                let drums = set == "gmd" || set == "candombe"
                for t in stride(from: 1.0, through: duration, by: 0.5) {
                    truth.append(ActivityTruth(t: t, bass: false, drums: drums)); silent.append(false)
                }
            }
            let seed = fnv1a(track.id)
            for condition in Condition.allCases {
                let pool = condition == .hall ? halls : rirs
                let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
                let x = RoomSim.apply(condition, to: audio, fs: fs, rir: rir, seed: seed)
                let rec = recordActivity(x, fs: fs)
                var j = 0
                for (k, t) in truth.enumerated() where !silent[k] {
                    while j + 1 < rec.times.count && rec.times[j + 1] <= t.t { j += 1 }
                    guard j < rec.times.count else { break }
                    windows.append(Window(set: set, cond: condition.rawValue, song: track.id, bass: rec.bass[j], drums: rec.drums[j], truth: t))
                }
                // How fast a lane notices: changes with ≥ 3 s of the other state on each side.
                guard set == "slakh" else { continue }
                for lane in ["bass", "drums"] {
                    let state = truth.map { lane == "bass" ? $0.bass : $0.drums }
                    let values = lane == "bass" ? rec.bass : rec.drums
                    for k in 6..<max(6, state.count - 6) where state[k] != state[k - 1] {
                        guard state[(k - 6)..<k].allSatisfy({ $0 == state[k - 1] }),
                              state[k..<(k + 6)].allSatisfy({ $0 == state[k] }) else { continue }
                        // The change happened in the window ending at truth[k].t (within its last 0.5 s).
                        let changeAt = truth[k].t - 0.5
                        var found: Double? = nil
                        for (i, tt) in rec.times.enumerated() where tt >= changeAt - 0.5 && tt <= changeAt + 5 {
                            if (values[i] >= 0.5) == state[k] { found = tt - changeAt; break }
                        }
                        notice["\(lane) \(condition.rawValue) \(state[k] ? "in" : "out")", default: []].append(found ?? 5)
                    }
                }
            }
        }
    }

    let conds = Condition.allCases.map(\.rawValue)
    print("activity: \(windows.count) windows, sets \(sets.joined(separator: ",")) (≤ \(perSet) each), \(rirs.count) rooms, \(halls.count) halls")
    for lane in ["bass", "drums"] {
        func v(_ w: Window) -> Float { lane == "bass" ? w.bass : w.drums }
        func t(_ w: Window) -> Bool { lane == "bass" ? w.truth.bass : w.truth.drums }
        print("\n== \(lane.uppercased()) — \(conds.joined(separator: " / "))")
        for (title, keep) in [("all songs", { (_: Window) in true }), ("held out", { (w: Window) in heldOut(w.song) })] {
            var bal = "  balanced accuracy, \(title):".padding(toLength: 40, withPad: " ", startingAt: 0)
            var per = "  per-song AUC (BabySlakh), \(title):".padding(toLength: 40, withPad: " ", startingAt: 0)
            for c in conds {
                let x = windows.filter { $0.cond == c && keep($0) }
                let p = x.filter(t), n = x.filter { !t($0) }
                let tpr = Double(p.filter { v($0) >= 0.5 }.count) / Double(max(1, p.count))
                let tnr = Double(n.filter { v($0) < 0.5 }.count) / Double(max(1, n.count))
                bal += String(format: " %5.2f", (tpr + tnr) / 2)
                let songs = Dictionary(grouping: x.filter { $0.set == "slakh" }, by: \.song).values
                let aucs = songs.map { g in rankAUC(g.filter(t).map(v), g.filter { !t($0) }.map(v)) }.filter { !$0.isNaN }
                per += String(format: " %5.2f", aucs.reduce(0, +) / Double(max(1, aucs.count)))
            }
            print(bal); print(per)
        }
        print("  read as on (share of windows), all songs:")
        for set in sets {
            var row = "    \(set)".padding(toLength: 40, withPad: " ", startingAt: 0)
            for c in conds {
                let x = windows.filter { $0.cond == c && $0.set == set }
                let on = Double(x.filter { v($0) >= 0.5 }.count) / Double(max(1, x.count))
                let truthOn = Double(x.filter(t).count) / Double(max(1, x.count))
                row += String(format: " %5.2f", on) + (set == "slakh" ? String(format: " (plays %.2f)", truthOn) : "")
            }
            print(row)
        }
        for dir in ["in", "out"] {
            var row = "  notice, comes \(dir) (s, median; n):".padding(toLength: 40, withPad: " ", startingAt: 0)
            for c in conds {
                let x = (notice["\(lane) \(c) \(dir)"] ?? []).sorted()
                row += x.isEmpty ? "     —" : String(format: " %5.1f (%d)", x[x.count / 2], x.count)
            }
            print(row)
        }
    }

    // A quiet room: pink noise alone at -70…-40 dBFS, 20 s each.
    print("\n== quiet room (pink noise alone, 20 s): mean bass / drums activity over the last 10 s")
    for dbfs in [-70.0, -60, -50, -40] {
        var rng = SplitMix(s: 919)
        var x = Synth.pinkNoise(count: Int(20 * fs), rng: &rng)
        let g = Float(pow(10, dbfs / 20) / Double(max(RoomSim.rms(x), 1e-9)))
        x = x.map { $0 * g }
        let rec = recordActivity(x, fs: fs)
        let tail = rec.times.indices.filter { rec.times[$0] >= 10 }
        let mb = tail.map { rec.bass[$0] }.reduce(0, +) / Float(max(1, tail.count))
        let md = tail.map { rec.drums[$0] }.reduce(0, +) / Float(max(1, tail.count))
        print(String(format: "  %4.0f dBFS: bass %.2f  drums %.2f", dbfs, mb, md))
    }
    print(String(format: "(%.0f s)", Date().timeIntervalSince(started)))
}
