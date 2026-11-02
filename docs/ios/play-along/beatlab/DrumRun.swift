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

/// What each lane may land on and still be right: the hi-hat lane is the
/// band's shimmer, so a ride or crash counts; a rim click counts as snare.
let laneFamily: [String: Set<String>] = ["kick": ["kick"], "snare": ["snare", "sidestick"],
                                         "hat": ["hat", "hatpedal", "cymbal"]]
