// DropRun.swift — build 921: does the app see a build coming, and land the drop?
//
//   run.sh -drop [-n 10]
//
// The whole live chain, causally (analyzer, tracker, clock, the song tracker
// with its energy states), clean and through the lab's rooms.
//  • Synthetic dance arrangements (ArrangementSynth), each at three tempos
//    (−3 %, as written, +3 %): every drop's true time is known.
//      called ahead  = one beat before the drop, the staged drop was within
//                      ±1 beat of it, at confidence ≥ 0.5 (and ≥ 0.8 — the
//                      Conductor only dims before a drop at ≥ 0.8);
//      lead          = how long before the drop that call had been standing
//                      (median over called drops);
//      confirmed     = within a bar after it, the tracker recorded a drop
//                      within a bar of it (recognised; timing is "called ahead");
//      false calls   = staged drops at ≥ 0.5 / ≥ 0.8 whose time passed with no
//                      drop within ±1 beat, per song;
//      states        = the share of bars whose state matches the section
//                      (build ↔ build, drop ↔ peak, breakdown ↔ breakdown,
//                      intro/verse/outro ↔ calm or groove).
//  • Real music with no drops at all (BabySlakh, Groove MIDI, GuitarSet,
//    Candombe), line and a room: every confident staged drop is a false
//    call — per minute of music.

import Foundation

@MainActor
func dropReport(_ args: [String]) {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let perSet = value("-n").flatMap(Int.init) ?? 10
    let fs = 48_000.0
    let manifest = try? Corpus.loadManifest()
    func loadRIRs(_ list: [String]?) -> [[Float]] {
        (list ?? []).compactMap { rel in (try? Corpus.loadAudio(Corpus.url(rel))).map { RoomSim.prepareRIR($0, fs: fs) } }
    }
    let rirs = loadRIRs(manifest?.rirs), halls = loadRIRs(manifest?.hallRirs)
    struct Tally {
        var drops = 0, called = 0, calledSure = 0, confirmed = 0, falseCalls = 0, falseSure = 0, songs = 0
        var leads: [Double] = []
        var stateBars = 0, stateRight = 0
        var fakeBuilds = 0, fakeCalled = 0, fakeEasedBack = 0
        var minutes = 0.0
    }
    var tally: [String: Tally] = [:]
    let started = Date()

    func at(_ tl: [(t: Double, s: SongStructure, beat: BeatSnapshot)], _ t: Double) -> SongStructure? {
        var lo = 0, hi = tl.count - 1, best: Int? = nil
        while lo <= hi { let m = (lo + hi) / 2; if tl[m].t <= t { best = m; lo = m + 1 } else { hi = m - 1 } }
        return best.map { tl[$0].s }
    }

    /// Staged drops at ≥ `minConfidence` whose time passed (one per staged time).
    func staged(_ tl: [(t: Double, s: SongStructure, beat: BeatSnapshot)], minConfidence: Double) -> [Double] {
        var out: [Double] = []
        for (i, p) in tl.enumerated() where i > 0 {
            let prev = tl[i - 1].s.energy
            guard prev.dropAt > 0, prev.dropConfidence >= minConfidence, prev.dropAt <= p.t,
                  prev.dropAt > tl[i - 1].t else { continue }
            if let last = out.last, abs(last - prev.dropAt) < 0.5 { continue }
            out.append(prev.dropAt)
        }
        return out
    }

    if let name = value("-debug"), let song = ArrangementSynth.songs.first(where: { $0.name == name }) {
        // Per bar, what the song tracker saw (line condition, the song as written).
        let r = ArrangementSynth.render(song, fs: fs)
        let clock = BeatClock(); clock.clear()
        let analyzer = OnsetFrameAnalyzer(), tracker = BeatTracker(), songTracker = SongStructureTracker()
        var nextPass = 0.5, printed = 0
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * 1024 <= r.samples.count {
                let start = Double(k * 1024) / fs, arrival = start + 1024 / fs + 0.004
                analyzer.process(p.baseAddress! + k * 1024, frameCount: 1024, sampleRate: fs, bufferStart: start)
                if arrival >= nextPass {
                    nextPass += 0.5
                    let frames = analyzer.snapshot(seconds: BeatTracker.windowSeconds + 2)
                    if let o = tracker.update(frames) { clock.ingest(observation: o) } else { clock.noteNoBeat(at: arrival) }
                    let s = songTracker.update(frames, beat: BeatClock.snapshot())
                    while printed < songTracker.bars.count {
                        let b = songTracker.bars[printed]
                        let part = r.sections.last { $0.time <= b.start + 0.1 }?.part.rawValue ?? "-"
                        print(String(format: "%6.1f %-10@ E %.2f bass %.2f drums %.2f dens %.2f flat %.3f high %.3f low %.3f | lvl %.2f score %.2f %@ drop %.1f conf %.2f",
                                     b.start, part as NSString, b.energy, b.bass, b.drums, b.density, b.flatness, b.high, b.low,
                                     s.energy.level, s.energy.buildScore, s.energy.state.rawValue as NSString, s.energy.dropAt, s.energy.dropConfidence))
                        printed += 1
                    }
                }
                k += 1
            }
        }
        return
    }
    // ── Synthetic arrangements ──
    for song in ArrangementSynth.songs {
        for scale in [0.97, 1.0, 1.03] {
            var variant = song
            variant.bpm = (song.bpm * scale).rounded()
            variant.seed = song.seed &+ UInt64(scale * 100)
            let r = ArrangementSynth.render(variant, fs: fs)
            let beatSec = 60 / r.bpm
            let seed = fnv1a("\(song.name)-\(variant.bpm)")
            let drops = r.drops
            let fakes = r.builds.filter { !$0.real }
            for condition in Condition.allCases {
                let pool = condition == .hall ? halls : rirs
                let rir = pool.isEmpty ? nil : pool[Int(seed % UInt64(pool.count))]
                let x = RoomSim.apply(condition, to: r.samples, fs: fs, rir: rir, seed: seed)
                let tl = structureTimeline(x, fs: fs)
                var t = tally["synth \(condition.rawValue)", default: Tally()]
                t.songs += 1
                for drop in drops {
                    t.drops += 1
                    if args.contains("-v"), condition == .room {
                        let s = at(tl, drop - beatSec)
                        let e = s?.energy ?? .none
                        let buildTruth = r.builds.last { $0.end <= drop + 0.01 }
                        print(String(format: "  %@ %3.0f drop %6.2f | staged %6.2f (%+.2f beats) conf %.2f state %@ buildStart %6.2f (truth %6.2f) phraseConf %.2f",
                                     song.name, variant.bpm, drop, e.dropAt, e.dropAt > 0 ? (e.dropAt - drop) / beatSec : .nan, e.dropConfidence,
                                     e.state.rawValue, e.buildStart, buildTruth?.start ?? 0, s?.phraseConfidence ?? 0))
                    }
                    if let s = at(tl, drop - beatSec)?.energy, s.dropAt > 0, abs(s.dropAt - drop) <= beatSec {
                        if s.dropConfidence >= 0.5 {
                            t.called += 1
                            // How long the call had been standing.
                            var lead = beatSec
                            for p in tl.reversed() where p.t < drop - beatSec {
                                let e = p.s.energy
                                guard e.dropAt > 0, abs(e.dropAt - drop) <= beatSec, e.dropConfidence >= 0.5 else { break }
                                lead = drop - p.t
                            }
                            t.leads.append(lead)
                        }
                        if s.dropConfidence >= 0.8 { t.calledSure += 1 }
                    }
                    // Recognised: within a bar after it, a drop recorded within a bar of it.
                    if let s = at(tl, drop + r.barSeconds + 1)?.energy, abs(s.lastDropAt - drop) <= r.barSeconds { t.confirmed += 1 }
                }
                if args.contains("-v"), condition == .line {
                    for d in staged(tl, minConfidence: 0.8) where !drops.contains(where: { abs($0 - d) <= beatSec }) {
                        let part = r.sections.last { $0.time <= d + 0.01 }
                        let nearest = drops.min { abs($0 - d) < abs($1 - d) } ?? 0
                        print(String(format: "  FALSE %@ %3.0f at %6.2f in %@ (bar %d of it), nearest drop %6.2f (%+.1f beats)", song.name, variant.bpm, d,
                                     (part?.part.rawValue ?? "-") as NSString, Int(((d - (part?.time ?? 0)) / r.barSeconds).rounded()), nearest, (d - nearest) / beatSec))
                    }
                }
                for (list, isSure) in [(staged(tl, minConfidence: 0.5), false), (staged(tl, minConfidence: 0.8), true)] {
                    let wrong = list.filter { d in !drops.contains { abs($0 - d) <= beatSec } }.count
                    if isSure { t.falseSure += wrong } else { t.falseCalls += wrong }
                }
                for fake in fakes {
                    t.fakeBuilds += 1
                    if staged(tl, minConfidence: 0.5).contains(where: { $0 >= fake.start && $0 <= fake.end + r.barSeconds }) { t.fakeCalled += 1 }
                    if let s = at(tl, fake.end + 2 * r.barSeconds)?.energy, s.state != .build, s.state != .peak { t.fakeEasedBack += 1 }
                }
                // States per bar against the sections.
                for (i, sec) in r.sections.enumerated() {
                    let end = i + 1 < r.sections.count ? r.sections[i + 1].time : r.duration
                    var bt = sec.time + r.barSeconds * 1.5
                    while bt < end {
                        if let s = at(tl, bt), s.hasSong {
                            t.stateBars += 1
                            let st = s.energy.state
                            let right: Bool
                            switch sec.part {
                            case .build, .fakeBuild: right = st == .build
                            case .drop: right = st == .peak
                            case .breakdown: right = st == .breakdown || st == .calm
                            case .intro, .verse, .outro: right = st == .calm || st == .groove
                            }
                            if right { t.stateRight += 1 }
                        }
                        bt += r.barSeconds
                    }
                }
                t.minutes += r.duration / 60
                tally["synth \(condition.rawValue)"] = t
            }
        }
    }

    // ── Real music without drops ──
    if let manifest {
        for set in ["slakh", "gmd", "guitarset", "candombe"] {
            let all = manifest.tracks.filter { $0.set == set }
            let step = max(1, all.count / perSet)
            for track in stride(from: 0, to: all.count, by: step).prefix(perSet).map({ all[$0] }) {
                guard var audio = try? Corpus.loadAudio(Corpus.url(track.audio)) else { continue }
                if audio.count > Int(180 * fs) { audio = Array(audio.prefix(Int(180 * fs))) }
                let seed = fnv1a(track.id)
                for condition in [Condition.line, .room] {
                    let rir = rirs.isEmpty ? nil : rirs[Int(seed % UInt64(rirs.count))]
                    let x = RoomSim.apply(condition, to: audio, fs: fs, rir: rir, seed: seed)
                    let tl = structureTimeline(x, fs: fs)
                    var t = tally["\(set) \(condition.rawValue)", default: Tally()]
                    t.songs += 1
                    t.falseCalls += staged(tl, minConfidence: 0.5).count
                    t.falseSure += staged(tl, minConfidence: 0.8).count
                    t.minutes += Double(audio.count) / fs / 60
                    tally["\(set) \(condition.rawValue)"] = t
                }
            }
        }
    }

    print(String(format: "drop: %d synthetic arrangements × 3 tempos, line/room/speaker/hall; real music without drops (≤ %d per set), line/room; %.0f s",
                 ArrangementSynth.songs.count, perSet, Date().timeIntervalSince(started)))
    print("set/cond          drops  called≥.5  called≥.8  lead(med s)  confirmed  false≥.5/song  false≥.8/song  fake builds: called, eased back   states right")
    for key in tally.keys.sorted() where key.hasPrefix("synth") {
        let t = tally[key]!
        let leads = t.leads.sorted()
        print(String(format: "%@ %6d %10.2f %10.2f %12.1f %10.2f %14.2f %14.2f        %d: %d, %d                %.2f",
                     pad(key, 16), t.drops, Double(t.called) / Double(max(1, t.drops)), Double(t.calledSure) / Double(max(1, t.drops)),
                     leads.isEmpty ? Double.nan : leads[leads.count / 2], Double(t.confirmed) / Double(max(1, t.drops)),
                     Double(t.falseCalls) / Double(max(1, t.songs)), Double(t.falseSure) / Double(max(1, t.songs)),
                     t.fakeBuilds, t.fakeCalled, t.fakeEasedBack, Double(t.stateRight) / Double(max(1, t.stateBars))))
    }
    print("\nReal music with no drops: false staged drops per minute (≥ 0.5 / ≥ 0.8)")
    for key in tally.keys.sorted() where !key.hasPrefix("synth") {
        let t = tally[key]!
        print(String(format: "%@ %3d songs, %5.1f min: %.2f / %.2f per minute", pad(key, 16), t.songs, t.minutes,
                     Double(t.falseCalls) / max(0.1, t.minutes), Double(t.falseSure) / max(0.1, t.minutes)))
    }
}
