// CorpusRun.swift — the shipping tracker (`runProd`) on real recordings, clean
// and through simulated rooms, scored with the standard measures.
//
//   run.sh -corpus                          every set, every condition
//   run.sh -corpus -set gmd -cond room      one set, one condition
//   run.sh -corpus -limit 20 -v             the first 20 tracks, a row each
//
// What is scored is what the lights would play: from each tracker pass to the
// next, the beats of the grid the clock published, only while Play Along
// would trust it (phase confidence ≥ 0.5, as Composer2PlayAlongDirector.usable)
// — downbeats only once the bar is trusted (bar confidence ≥ 0.5, as
// Composer2Quantizer). Annotations come from the corpus; no audio is written.

import Foundation

struct Played {
    var beats: [Double] = []
    var downbeats: [Double] = []
}

/// The beats the room would get from a run of clock snapshots.
func playedBeats(_ snaps: [Snap], usableConfidence: Double = 0.5, barConfidence: Double = 0.5) -> Played {
    var out = Played()
    for k in snaps.indices {
        let s = snaps[k].s
        let t0 = snaps[k].t
        let t1 = k + 1 < snaps.count ? snaps[k + 1].t : t0 + 0.5
        guard s.bpm > 0, s.beatInterval.isFinite, s.beatInterval > 0, s.phaseConfidence >= usableConfidence else { continue }
        var n = Int(ceil((t0 - s.beatEpoch) / s.beatInterval))
        while true {
            let t = s.beatEpoch + Double(n) * s.beatInterval
            if t >= t1 { break }
            if t >= t0 {
                // A grid shift can put a beat right after the last one; the
                // room would see one beat, not two.
                if let last = out.beats.last, t - last < s.beatInterval * 0.5 { n += 1; continue }
                out.beats.append(t)
                let per = max(1, s.beatsPerBar)
                if s.barConfidence >= barConfidence, ((n % per) + per) % per == 0 { out.downbeats.append(t) }
            }
            n += 1
        }
    }
    return out
}

struct TrackScore {
    var id: String
    var set: String
    var condition: Condition
    var seconds: Double
    var f: Double
    /// The grid's own accuracy whenever it has a tempo, trusted or not: low
    /// F with a high grid F means the beat was right but never trusted.
    var gridF: Double
    var continuity: Metrics.Continuity
    var downbeatF: Double?
    var lock: Double?
    var tempoRatio: Double?
}

@MainActor
func corpusReport(_ args: [String]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let manifest: CorpusManifest
    do { manifest = try Corpus.loadManifest() } catch {
        print("No corpus manifest at \(Corpus.manifestURL.path) — run `run.sh -import …` first (\(error))")
        return
    }
    let sets = value("-set").map { Set($0.split(separator: ",").map(String.init)) }
    let conditions: [Condition] = value("-cond").map { $0.split(separator: ",").compactMap { Condition(rawValue: String($0)) } }
        ?? Condition.allCases
    let limit = value("-limit").flatMap(Int.init) ?? .max
    let verbose = args.contains("-v")
    let tracks = manifest.tracks.filter { $0.beats != nil && (sets?.contains($0.set) ?? true) }.prefix(limit)
    func load(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: 48_000) } }
    }
    let rirs = load(manifest.rirs), halls = load(manifest.hallRirs)
    if conditions.contains(where: { $0 != .line }) && rirs.isEmpty {
        print("note: no room impulse responses in the manifest — rooms use the mic band and noise only")
    }
    print("corpus \(Corpus.root.path): \(tracks.count) tracks, conditions \(conditions.map(\.rawValue).joined(separator: ",")), \(rirs.count) home-like rooms, \(halls.count) halls")

    var scores: [TrackScore] = []
    let started = Date()
    for track in tracks {
        guard let beatsPath = track.beats,
              let ref = try? Corpus.readBeats(Corpus.url(beatsPath)), ref.count >= 8 else { continue }
        let audio: [Float]
        do { audio = try Corpus.loadAudio(Corpus.url(track.audio)) } catch {
            print("  skip \(track.id): \(error.localizedDescription)")
            continue
        }
        let fs = 48_000.0
        let refBeats = ref.map(\.time)
        let refDown = ref.filter { $0.beatInBar == 1 }.map(\.time)
        let hasBars = !refDown.isEmpty && ref.contains { $0.beatInBar > 1 }
        let seed = fnv1a(track.id)
        for condition in conditions {
            let pool = condition == .hall ? halls : rirs
            let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
            let x = RoomSim.apply(condition, to: audio, fs: fs, rir: rir, seed: seed)
            let snaps = runProd(Rendered(samples: x, beats: [], fs: fs))
            let played = playedBeats(snaps)
            let s = TrackScore(
                id: track.id, set: track.set, condition: condition, seconds: Double(audio.count) / fs,
                f: Metrics.beatF(ref: refBeats, est: played.beats),
                gridF: Metrics.beatF(ref: refBeats, est: playedBeats(snaps, usableConfidence: 0).beats),
                continuity: Metrics.continuity(ref: refBeats, est: played.beats),
                downbeatF: hasBars ? Metrics.beatF(ref: refDown, est: played.downbeats) : nil,
                lock: Metrics.lockTime(ref: refBeats, est: played.beats, from: refBeats.first ?? 0),
                tempoRatio: Metrics.tempoRatio(ref: refBeats, est: played.beats))
            scores.append(s)
            if verbose {
                print(String(format: "  %@ %@ %5.0fs  F %.2f  grid F %.2f  CMLt %.2f  AMLt %.2f  downbeat %@  lock %@  tempo ×%@",
                             pad(String(track.id.suffix(60)), 60) as NSString, pad(condition.rawValue, 7) as NSString,
                             s.seconds, s.f, s.gridF,
                             s.continuity.cmlT, s.continuity.amlT,
                             (s.downbeatF.map { String(format: "%.2f", $0) } ?? "  — ") as NSString,
                             (s.lock.map { String(format: "%4.1fs", $0) } ?? "never") as NSString,
                             (s.tempoRatio.map { String(format: "%.2f", $0) } ?? "—") as NSString))
            }
        }
    }
    printSummary(scores)
    print(String(format: "(%.0f s)", Date().timeIntervalSince(started)))
}

func printSummary(_ scores: [TrackScore]) {
    let groups = Dictionary(grouping: scores) { "\($0.set)|\($0.condition.rawValue)" }
    print("")
    print("set          cond     tracks  beat F  grid F  CMLt  AMLt  downbeat F  lock med  never  right tempo  ×2 (half time)  ×½ (double)")
    for key in groups.keys.sorted() {
        let g = groups[key]!
        let parts = key.split(separator: "|")
        let locks = g.compactMap(\.lock)
        let ratios = g.compactMap(\.tempoRatio)
        func share(_ p: (Double) -> Bool) -> Double { ratios.isEmpty ? 0 : Double(ratios.filter(p).count) / Double(g.count) * 100 }
        let db = g.compactMap(\.downbeatF)
        print(String(format: "%@ %@ %6d  %6.3f  %6.3f %5.3f %5.3f  %@  %@  %5d  %10.0f%%  %13.0f%%  %10.0f%%",
                     pad(String(parts[0]), 12) as NSString, pad(String(parts[1]), 8) as NSString, g.count,
                     Metrics.mean(g.map(\.f)) ?? 0, Metrics.mean(g.map(\.gridF)) ?? 0,
                     Metrics.mean(g.map(\.continuity.cmlT)) ?? 0,
                     Metrics.mean(g.map(\.continuity.amlT)) ?? 0,
                     (db.isEmpty ? "         —" : String(format: "%10.3f", Metrics.mean(db)!)) as NSString,
                     (Metrics.median(locks).map { String(format: "%7.1fs", $0) } ?? "       —") as NSString,
                     g.count - locks.count,
                     share { abs($0 - 1) < 0.04 }, share { abs($0 - 2) < 0.08 }, share { abs($0 - 0.5) < 0.02 }))
    }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s.padding(toLength: n, withPad: " ", startingAt: 0) }

/// A stable 64-bit hash of a string (track ids pick rooms and noise).
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}
