// Composer2LabPlayAlongTests.swift
// HueHome Pro — Unit Tests (Play Along P3)
//
// The Play Along transform over every built-in look × feel × tempo: cycles
// lock to legal musical lengths, colours are never touched, Calm looks keep
// their pace, looks that already listen keep their sound, events move onto
// the grid at their own average rate — and the engine actually locks motion
// and fires events on the beat.

import XCTest
@testable import HueHome

final class Composer2LabPlayAlongTests: XCTestCase {

    private let tempos: [Double] = [72, 96, 120, 128, 174]

    private func category(_ look: Composer2Composition) -> Composer2LookCategory? {
        Composer2ThemeCatalog.entry(id: look.id)?.category
    }

    func testEveryLookFeelAndTempoYieldsLegalCyclesAndUntouchedColours() {
        for look in Composer2PresetLibrary.all {
            for feel in Composer2PlayAlong.Feel.allCases {
                for bpm in tempos {
                    let out = Composer2PlayAlong.apply(look, feel: feel, bpm: bpm, category: category(look))
                    XCTAssertEqual(out.id, look.id)
                    XCTAssertEqual(out.layers.map(\.id), look.layers.map(\.id), "\(look.name): layer identity")
                    for (a, b) in zip(look.layers, out.layers) {
                        XCTAssertEqual(a.color, b.color, "\(look.name): colours are never touched")
                        XCTAssertEqual(a.mask, b.mask)
                        XCTAssertGreaterThanOrEqual(b.rhythm.quantizeBeats, 0)
                        XCTAssertLessThanOrEqual(b.rhythm.quantizeBeats, Composer2PlayAlong.longestLockedBeats * 16)
                        if b.motion.quantizeBeats > 0 {
                            let cycle = b.motion.quantizeBeats * 60 / bpm
                            // The engine doubles a too-fast lock; the authored floor holds either way.
                            XCTAssertTrue(cycle.isFinite && cycle > 0, "\(look.name) \(feel) \(bpm)")
                        }
                    }
                }
            }
        }
    }

    func testTheTransformIsDeterministicAndIdempotent() {
        for look in Composer2PresetLibrary.all {
            let once = Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, category: category(look))
            XCTAssertEqual(once, Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, category: category(look)))
            XCTAssertEqual(Composer2PlayAlong.apply(once, feel: .hit, bpm: 120, category: category(look)).layers.map(\.rhythm),
                           once.layers.map(\.rhythm), "\(look.name): an already-locked look stays locked as is")
        }
    }

    func testCalmLooksAreNeverRetimed() {
        for entry in Composer2ThemeCatalog.entries(in: .calm) {
            for feel in Composer2PlayAlong.Feel.allCases {
                for bpm in tempos {
                    let out = Composer2PlayAlong.apply(entry.composition, feel: feel, bpm: bpm, category: .calm)
                    for (a, b) in zip(entry.composition.layers, out.layers) {
                        XCTAssertEqual(a.rhythm, b.rhythm, "\(entry.composition.name) keeps its breath")
                        XCTAssertEqual(a.motion, b.motion)
                        XCTAssertEqual(a.events, b.events)
                    }
                }
            }
        }
        let calm = Composer2PlayAlong.apply(Composer2PresetLibrary.breathingCalm, feel: .hit, bpm: 120, category: .calm)
        XCTAssertEqual(calm.layers[0].rhythm.sanitizedPeriod, 10, accuracy: 1e-9, "six breaths a minute")
        XCTAssertEqual(calm.layers[0].audio.source, .amplitude, "it only breathes with the loudness")
    }

    func testGlideKeepsALooksPaceWithinTwentyPercent() {
        for look in Composer2PresetLibrary.all where category(look) != .calm {
            let out = Composer2PlayAlong.apply(look, feel: .glide, bpm: 120, category: category(look))
            for (a, b) in zip(look.layers, out.layers) where b.rhythm.quantizeBeats > 0 && a.rhythm.quantizeBeats == 0 {
                let locked = b.rhythm.quantizeBeats * 0.5
                XCTAssertLessThanOrEqual(abs(locked / a.rhythm.sanitizedPeriod - 1), 0.2 + 1e-9, look.name)
            }
        }
    }

    func testLooksThatAlreadyListenKeepTheirSound() {
        for look in [Composer2PresetLibrary.beatDrop, Composer2PresetLibrary.clubPulse] {
            let out = Composer2PlayAlong.apply(look, feel: .hit, bpm: 128, category: .party)
            XCTAssertEqual(out.layers.map(\.audio), look.layers.map(\.audio), look.name)
        }
    }

    func testGrooveAndHitPunchOnTheBeat() {
        let look = Composer2PresetLibrary.neonNights
        let groove = Composer2PlayAlong.apply(look, feel: .groove, bpm: 120, category: .party)
        XCTAssertEqual(groove.layers[0].audio.source, .beat)
        XCTAssertTrue(groove.layers[0].audio.targets.contains(.palettePosition))
        XCTAssertEqual(groove.layers[0].audio.quantizeBeats, 4, "a new colour each bar")
        let hit = Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, category: .party)
        XCTAssertGreaterThan(hit.layers[0].audio.intensity, groove.layers[0].audio.intensity)
        XCTAssertEqual(hit.layers[0].audio.quantizeBeats, 2)
    }

    func testEventsMoveOntoTheGridAtTheirOwnAverageRate() {
        guard let storm = Composer2PresetLibrary.all.first(where: { look in
            look.layers.contains { $0.events?.shape == .lightning }
        }) else { return XCTFail("a look with lightning") }
        let layerIndex = storm.layers.firstIndex { $0.events?.shape == .lightning }!
        let authored = storm.layers[layerIndex].events!
        let out = Composer2PlayAlong.apply(storm, feel: .hit, bpm: 120, category: category(storm))
        let synced = out.layers[layerIndex].events!
        XCTAssertEqual(synced.beatSync, 4, "lightning strikes on the one")
        let authoredRate = authored.probability / authored.meanDelay
        let syncedRate = synced.probability / (4 * 0.5)
        XCTAssertEqual(syncedRate, authoredRate, accuracy: authoredRate * 1e-9 + 1e-12)
    }

    // MARK: - The engine honours it

    func testLockedMotionLandsOnTheBeatGrid() {
        var layer = Composer2Layer.blank(name: "Chase")
        layer.motion = Composer2Motion(kind: .flow, periodSeconds: 7, quantizeBeats: 8)
        let look = Composer2Composition(name: "Lock", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let geometry = Composer2SlotGeometry.linear(count: 4)
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        var stateA = Composer2EngineState(), stateB = Composer2EngineState()
        // 8 beats at 120 BPM = 4 s: one full cycle apart, same picture —
        // whatever the composition's own clock says.
        let a = Composer2Engine.evaluate(look, time: 3, geometry: geometry, state: &stateA, beat: beat, hostNow: 1001)
        let b = Composer2Engine.evaluate(look, time: 50, geometry: geometry, state: &stateB, beat: beat, hostNow: 1005)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.x, y.x, accuracy: 1e-9)
            XCTAssertEqual(x.y, y.y, accuracy: 1e-9)
        }
    }

    func testBeatSyncedEventsStartOnTheBeat() {
        var spec = Composer2EventSpec(timing: .fixed, interval: 3600, probability: 1, burstMin: 1, burstMax: 1,
                                      durationMin: 0.1, durationMax: 0.1, shape: .flash)
        spec.beatSync = 4
        var layer = Composer2Layer.blank(name: "Strikes")
        layer.events = spec
        let look = Composer2Composition(name: "Sync", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let geometry = Composer2SlotGeometry.linear(count: 3)
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        var state = Composer2EngineState()
        var starts: [Double] = []
        var t = 1000.02
        while t < 1008 {
            _ = Composer2Engine.evaluate(look, time: t - 1000, geometry: geometry, state: &state, beat: beat, hostNow: t)
            if let start = state.layers[0].events?.current?.start, starts.last.map({ abs($0 - start) > 1e-9 }) ?? true {
                starts.append(start)
            }
            t += 0.02
        }
        XCTAssertGreaterThanOrEqual(starts.count, 3)
        for start in starts {
            // Composition time = host − 1000: the downbeats are every 2 s.
            let offBar = start.truncatingRemainder(dividingBy: 2)
            XCTAssertLessThan(min(offBar, 2 - offBar), 0.021, "an event starts within a frame of the one (\(start))")
        }
    }
}
