// Composer2LabPersistenceTests.swift
// ChromaGlow — Composer 2 lab. Codable round trips, the separate store, and
// the proof that the legacy composition store is untouched.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabPersistenceTests: XCTestCase {

    private var tempDir: URL!
    private var savedOnPersist: (() -> Void)?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer2-lab-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedOnPersist = CompositionStore.onPersist
    }

    override func tearDown() {
        CompositionStore.onPersist = savedOnPersist
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Every enum case, events, masks, extreme seeds, whole-second dates.
    private func maximal() -> Composer2Composition {
        var layers: [Composer2Layer] = []
        let kinds = Composer2Motion.Kind.allCases
        let shapes = Composer2Rhythm.Shape.allCases
        let blends = Composer2BlendMode.allCases
        let masks = Composer2LayerMask.Kind.allCases
        let sources = Composer2AudioModulation.Source.allCases
        let styles = Composer2ColorSource.Interpolation.allCases
        for i in 0..<7 {
            var layer = Composer2Layer(name: "L\(i)", enabled: i % 2 == 0, opacity: Double(i) / 6,
                                       blend: blends[i % blends.count])
            layer.mask = Composer2LayerMask(kind: masks[i % masks.count], slots: [i, i + 1], lightIDs: ["a\(i)"],
                                            fraction: 0.3, count: i % 2 == 0 ? i : nil,
                                            regionX0: 0.1, regionZ0: 0.2, regionX1: 0.8, regionZ1: 0.9,
                                            feather: 0.25, invert: i % 3 == 0)
            layer.color = Composer2ColorSource(stops: (0..<(i + 1)).map { Composer2PaletteStop(x: 0.3 + 0.03 * Double($0), y: 0.3, position: $0 == 0 ? nil : 0.1 * Double($0)) },
                                               interpolation: styles[i % styles.count], saturation: 1.2, warmth: -0.4,
                                               distribution: Composer2ColorSource.Distribution.allCases[i % 4], drift: 0.2, cycle: i % 2 == 0)
            layer.motion = Composer2Motion(kind: kinds[i % kinds.count], periodSeconds: 3 + Double(i),
                                           axisKind: Composer2Motion.AxisKind.allCases[i % 4], angleDegrees: 33,
                                           spread: 0.4, phaseOffset: 0.1, reverse: i % 2 == 1, mirror: i % 3 == 1,
                                           smoothness: 0.6, travelWidth: 0.5, steps: i, edge: Composer2Motion.Edge.allCases[i % 3], scale: 1.5)
            layer.rhythm = Composer2Rhythm(shape: shapes[i % shapes.count], periodSeconds: 2 + Double(i), attack: 0.3,
                                           decay: 0.7, depth: 0.4, duty: 0.6, minBrightness: 0.1, maxBrightness: 0.9,
                                           phase: 0.25, quantizeBeats: Double(i), flickerRate: 2)
            layer.audio = Composer2AudioModulation(source: sources[i % sources.count], sensitivity: 0.5, threshold: 0.2,
                                                   smoothing: 0.4, intensity: 0.8, targets: [.brightness, .motionSpeed],
                                                   quantizeBeats: 2, paletteStep: 0.5, punchDecay: 0.3, triggerEventsOnOnset: true)
            layer.variation = Composer2Variation(amount: 0.7, seed: i == 0 ? 0 : (i == 1 ? UInt64.max : nil),
                                                 speedVariation: 0.1, brightnessVariation: 0.2, paletteDrift: 0.3,
                                                 perLightPhase: 0.4, eventTiming: 0.5, spatialRandomness: 0.6, evolveRate: 0.07)
            layer.events = i % 2 == 0 ? Composer2EventSpec(timing: i % 4 == 0 ? .fixed : .random, interval: 3, minDelay: 1,
                                                           maxDelay: 5, probability: 0.4, burstMin: 1, burstMax: 4,
                                                           spacingMin: 0.34, spacingMax: 0.9, durationMin: 0.05,
                                                           durationMax: 0.2, decaySeconds: 0.4, intensityMin: 0.3,
                                                           intensityMax: 0.9, targeting: Composer2EventSpec.Targeting.allCases[i % 3],
                                                           targetCount: 2, spatialBias: 0.6, cooldown: 1.5, majorProbability: 0.1,
                                                           seed: UInt64.max - 1, modulates: [.brightness, .color, .motion],
                                                           color: Composer2XY(x: 0.3, y: 0.3), motionKick: 0.2) : nil
            layers.append(layer)
        }
        var c = Composer2Composition(id: UUID(), name: "Maximal", subtitle: "Everything on",
                                     createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     updatedAt: Date(timeIntervalSince1970: 1_700_000_100), isBuiltIn: false,
                                     sourcePresetID: UUID(), target: Composer2TargetHint(roomID: "r", bridgeID: "b"),
                                     master: Composer2MasterControls(intensity: 0.8, speed: 1.5, energy: 0.3, variation: 0.9, seed: UInt64.max),
                                     layers: layers)
        c.schema = Composer2Composition.currentSchema
        return c
    }

    func testMaximalCompositionRoundTrips() throws {
        let original = maximal()
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(Composer2Composition.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.master.seed, UInt64.max)
        XCTAssertEqual(decoded.layers[1].variation.seed, UInt64.max)
        XCTAssertEqual(decoded.layers[0].variation.seed, 0)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schema\":1"))
        XCTAssertTrue(text.contains("\"seed\":\"18446744073709551615\""), "seeds must be strings")
    }

    func testTolerantDecoding() throws {
        let id = UUID().uuidString
        let onlyID = try decoder().decode(Composer2Composition.self, from: Data("{\"id\":\"\(id)\"}".utf8))
        XCTAssertEqual(onlyID.id.uuidString, id)
        XCTAssertEqual(onlyID.layers, [])
        XCTAssertEqual(onlyID.name, "Untitled")

        let json = """
        {"id":"\(id)","schema":99,"layers":[
          {"id":"\(UUID().uuidString)","motion":{"kind":"banana","periodSeconds":"x"},"variation":{"seed":42}},
          "nope",
          {"id":"\(UUID().uuidString)","variation":{"seed":"43"},"audio":{"source":"laser"}}
        ]}
        """
        let c = try decoder().decode(Composer2Composition.self, from: Data(json.utf8))
        XCTAssertEqual(c.layers.count, 2, "the malformed layer is dropped, not fatal")
        XCTAssertEqual(c.layers[0].motion.kind, .flow, "unknown kind falls back to the default")
        XCTAssertEqual(c.layers[0].motion.periodSeconds, 8)
        XCTAssertEqual(c.layers[0].variation.seed, 42)
        XCTAssertEqual(c.layers[1].variation.seed, 43)
        XCTAssertEqual(c.layers[1].audio.source, .off)
        XCTAssertEqual(c.schema, 99)
    }

    // MARK: Store

    func testStoreRoundTripDeleteDuplicateAndFilename() {
        let url = tempDir.appendingPathComponent("composer2-compositions.json")
        let store = Composer2Store(fileURL: url)
        XCTAssertTrue(Composer2Store.defaultFileURL.lastPathComponent == "composer2-compositions.json")
        let saved = store.save(maximal(), at: Date(timeIntervalSince1970: 1_700_000_200))
        let second = store.save(Composer2PresetLibrary.thunderstorm, at: Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertNotEqual(second.id, Composer2PresetLibrary.thunderstorm.id, "saving a built-in stores a copy")
        XCTAssertFalse(second.isBuiltIn)
        let reloaded = Composer2Store(fileURL: url)
        XCTAssertEqual(reloaded.compositions.map(\.id), [saved.id, second.id])
        XCTAssertEqual(reloaded.compositions[0], saved)
        XCTAssertEqual(reloaded.all.count, Composer2PresetLibrary.all.count + 2)
        let copy = store.duplicate(saved, at: Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertEqual(copy.layers.count, saved.layers.count)
        XCTAssertNotEqual(copy.id, saved.id)
        store.delete(id: saved.id)
        XCTAssertEqual(Composer2Store(fileURL: url).compositions.map(\.id), [second.id, copy.id])
        let text = String(decoding: try! Data(contentsOf: url), as: UTF8.self)
        for preset in Composer2PresetLibrary.all {
            XCTAssertFalse(text.contains(preset.id.uuidString), "built-ins are never persisted")
        }
    }

    func testCorruptFileYieldsEmptyAndIsNotOverwrittenByLoading() throws {
        let url = tempDir.appendingPathComponent("composer2-compositions.json")
        let garbage = Data("{not json at all".utf8)
        try garbage.write(to: url)
        let store = Composer2Store(fileURL: url)
        XCTAssertTrue(store.compositions.isEmpty)
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(try Data(contentsOf: url), garbage)
        XCTAssertEqual(Composer2Store.readCompositions(from: url), [])
        // A later save sets the unreadable file aside instead of overwriting it.
        store.save(Composer2PresetLibrary.lavaLamp)
        let aside = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(aside[0])), garbage)
    }

    func testLegacyCompositionStoreIsUnaffected() throws {
        let legacyURL = tempDir.appendingPathComponent("compositions.json")
        let presets = Array(CompositionStore.builtInPresets.prefix(3))
        try JSONEncoder().encode(presets).write(to: legacyURL)
        let bytesBefore = try Data(contentsOf: legacyURL)
        let readBefore = CompositionStore.readPresets(from: legacyURL).presets
        var fired = false
        CompositionStore.onPersist = { fired = true }

        let store = Composer2Store(fileURL: tempDir.appendingPathComponent("composer2-compositions.json"))
        let a = store.save(Composer2PresetLibrary.auroraDrift)
        store.save(Composer2PresetLibrary.hauntedHouse)
        store.delete(id: a.id)

        XCTAssertEqual(try Data(contentsOf: legacyURL), bytesBefore)
        XCTAssertEqual(CompositionStore.readPresets(from: legacyURL).presets, readBefore)
        XCTAssertFalse(fired, "the legacy persist hook must never fire")
        let baks = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.hasPrefix("compositions-") }
        XCTAssertTrue(baks.isEmpty)
    }

    // MARK: Legacy import

    private func legacy(_ mutate: (inout CompositionPreset) -> Void) -> CompositionPreset {
        var p = CompositionStore.builtInPresets[0]
        mutate(&p)
        return p
    }

    func testImportPreservesColoursAndMapsSpectrum() {
        let p = legacy {
            $0.palette.mode = .gradient
            $0.palette.color1 = CodableColor(x: 0.6, y: 0.3)
            $0.palette.color2 = CodableColor(x: 0.2, y: 0.5)
            $0.palette.color3 = CodableColor(x: 0.3, y: 0.2)
        }
        let layer = Composer2LegacyImport.layer(from: p)
        XCTAssertEqual(layer.color.stops.map { [$0.x, $0.y] }, [[0.6, 0.3], [0.2, 0.5], [0.3, 0.2]])
        XCTAssertEqual(layer.color.interpolation, .linear)
        let spectrum = Composer2LegacyImport.layer(from: legacy { $0.palette.mode = .spectrum })
        XCTAssertEqual(spectrum.color.stops.count, 8)
        XCTAssertEqual(spectrum.color.interpolation, .hueArc)
    }

    func testEveryLegacyPatternMapsAndPeriodIsPreserved() {
        for pattern in MotionConfig.Pattern.allCases {
            let p = legacy { $0.motion.pattern = pattern; $0.motion.speed = 55; $0.motion.forward = false }
            let layer = Composer2LegacyImport.layer(from: p)
            XCTAssertEqual(layer.motion.periodSeconds, p.motion.periodSeconds, accuracy: 1e-12, "\(pattern)")
            XCTAssertTrue(layer.motion.reverse)
            switch pattern {
            case .static, .twinkle: XCTAssertEqual(layer.motion.kind, .static)
            case .cascade, .spiral: XCTAssertEqual(layer.motion.kind, .flow)
            case .wave, .pulseCenter: XCTAssertEqual(layer.motion.kind, .wave)
            case .scatter: XCTAssertEqual(layer.motion.kind, .scatter)
            case .bounce: XCTAssertEqual(layer.motion.kind, .bounce)
            case .chase, .comet: XCTAssertEqual(layer.motion.kind, .chase)
            }
            if pattern == .twinkle { XCTAssertNotNil(layer.events) } else { XCTAssertNil(layer.events) }
            if pattern == .pulseCenter { XCTAssertEqual(layer.motion.axisKind, .radial) }
            if pattern == .spiral { XCTAssertEqual(layer.motion.axisKind, .angular) }
        }
    }

    func testEnvelopeAndReactionMap() {
        let p = legacy {
            $0.envelope.shape = .heartbeat; $0.envelope.bpm = 120; $0.envelope.depth = 40
            $0.envelope.minBrightness = 20; $0.envelope.maxBrightness = 90
            $0.reaction.source = .micBass; $0.reaction.targets = [.color, .speed]; $0.reaction.sensitivity = 80
        }
        let layer = Composer2LegacyImport.layer(from: p)
        XCTAssertEqual(layer.rhythm.shape, .heartbeat)
        XCTAssertEqual(layer.rhythm.periodSeconds, 0.5, accuracy: 1e-12)
        XCTAssertEqual(layer.rhythm.depth, 0.4, accuracy: 1e-12)
        XCTAssertEqual(layer.rhythm.minBrightness, 0.2, accuracy: 1e-12)
        XCTAssertEqual(layer.audio.source, .bass)
        XCTAssertEqual(layer.audio.targets, [.palettePosition, .motionSpeed])
        XCTAssertEqual(layer.audio.sensitivity, 0.8, accuracy: 1e-12)
    }

    func testImportIsNonDestructiveIdempotentAndRendersLegally() {
        let p = CompositionStore.builtInPresets[2]
        let copy = p
        let a = Composer2LegacyImport.composition(from: p, now: Date(timeIntervalSince1970: 0))
        let b = Composer2LegacyImport.composition(from: p, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(p, copy)
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, p.id)
        XCTAssertEqual(a.sourcePresetID, p.id)
        var state = Composer2EngineState()
        let g = Composer2SlotGeometry.linear(count: 5)
        for i in 0..<25 {
            let frames = Composer2Engine.evaluate(a, time: Double(i) * 0.04, geometry: g, state: &state)
            XCTAssertEqual(frames.count, 5)
            for f in frames { XCTAssertTrue(f.isValid) }
        }
    }

    func testSolidStaticSteadyImportMatchesLegacyFrames() {
        let p = legacy {
            $0.palette.mode = .solid
            $0.palette.color1 = CodableColor(x: 0.45, y: 0.41)
            $0.motion.pattern = .static
            $0.envelope.shape = .steady
            $0.envelope.maxBrightness = 100
            $0.reaction.source = .none
        }
        let legacyFrames = CompositionEngine.render(time: 2, channelIDs: [0, 1, 2], params: CompositionParamBox(preset: p))
        let imported = Composer2LegacyImport.composition(from: p, now: Date(timeIntervalSince1970: 0))
        var state = Composer2EngineState()
        let frames = Composer2Engine.evaluate(imported, time: 2, geometry: .linear(count: 3), state: &state)
        for (l, c) in zip(legacyFrames, frames) {
            XCTAssertEqual(l.x, c.x, accuracy: 2e-3)
            XCTAssertEqual(l.y, c.y, accuracy: 2e-3)
            XCTAssertEqual(l.brightness, c.brightness, accuracy: 0.02)
        }
    }
}
