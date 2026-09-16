// Composer2LabEngineTests.swift
// ChromaGlow — Composer 2 lab. The pure evaluator and the render-hook runtime.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabEngineTests: XCTestCase {

    private func geometry(_ n: Int) -> Composer2SlotGeometry {
        var points: [(x: Double, z: Double)] = []
        let denominator = Double(max(1, n - 1))
        for i in 0..<n {
            let x: Double = Double(i) / denominator
            let z: Double = 0.3 + 0.2 * Double(i % 2)
            points.append((x: x, z: z))
        }
        return Composer2SlotGeometry(points: points)
    }

    private func sequence(_ c: Composer2Composition, slots: Int, frames: Int = 250, dt: Double = 0.04,
                          audio: AudioFeatures = .silent) -> [[Composer2Frame]] {
        var state = Composer2EngineState()
        let g = geometry(slots)
        return (0..<frames).map { Composer2Engine.evaluate(c, time: Double($0) * dt, geometry: g, state: &state, audio: audio) }
    }

    private func assertLegal(_ frames: [Composer2Frame], _ context: String) {
        for f in frames {
            XCTAssertTrue(f.isValid, "\(context): invalid frame \(f)")
            let c = HueColorUtils.clampXYToGamut(x: f.x, y: f.y, gamut: .c)
            XCTAssertEqual(c.x, f.x, accuracy: 1e-9, "\(context) x outside gamut C")
            XCTAssertEqual(c.y, f.y, accuracy: 1e-9, "\(context) y outside gamut C")
        }
    }

    func testSameSeedProducesIdenticalFrameSequences() {
        for preset in Composer2PresetLibrary.all {
            XCTAssertEqual(sequence(preset, slots: 12), sequence(preset, slots: 12), preset.name)
        }
    }

    func testDifferentSeedProducesDifferentFrames() {
        var other = Composer2PresetLibrary.auroraDrift
        other.master.seed = 42
        let a = sequence(Composer2PresetLibrary.auroraDrift, slots: 8, frames: 60)
        let b = sequence(other, slots: 8, frames: 60)
        XCTAssertNotEqual(a, b)
    }

    func testFrameCountMatchesForEveryRoomSizeAndOutputIsLegal() {
        for preset in Composer2PresetLibrary.all {
            for n in [0, 1, 5, 20, 21, 64, 300] {
                var state = Composer2EngineState()
                for i in 0..<20 {
                    let frames = Composer2Engine.evaluate(preset, time: Double(i) * 0.04, geometry: geometry(n), state: &state)
                    XCTAssertEqual(frames.count, n, "\(preset.name) at \(n) slots")
                    assertLegal(frames, "\(preset.name) n=\(n) frame \(i)")
                }
            }
        }
    }

    func testAudioOffLeavesAccumulatorsAtIdentity() {
        var state = Composer2EngineState()
        let g = geometry(6)
        for i in 0..<100 {
            _ = Composer2Engine.evaluate(Composer2PresetLibrary.lavaLamp, time: Double(i) * 0.04, geometry: g, state: &state)
        }
        for layer in state.layers {
            XCTAssertEqual(layer.warpOffset, 0)
            XCTAssertEqual(layer.smoothedDrive, 0)
        }
    }

    private let reactiveComposition: Composer2Composition = {
        var layer = Composer2Layer(id: UUID(uuidString: "0000000C-00AA-00AA-00AA-000000000001")!,
                                   name: "Reactive", color: .solid(Composer2XY(x: 0.5, y: 0.4)),
                                   motion: Composer2Motion(kind: .flow, periodSeconds: 6),
                                   rhythm: Composer2Rhythm(shape: .steady))
        layer.audio = Composer2AudioModulation(source: .amplitude, sensitivity: 0.8, threshold: 0,
                                               smoothing: 0, intensity: 1,
                                               targets: [.brightness, .motionSpeed, .eventProbability])
        layer.events = Composer2EventSpec(timing: .random, minDelay: 1, maxDelay: 2, probability: 0.2,
                                          burstMin: 1, burstMax: 1, durationMin: 0.01, durationMax: 0.01, decaySeconds: 0.01)
        return Composer2Composition(id: UUID(uuidString: "0000000C-00AA-00AA-00AA-000000000002")!,
                                    name: "Reactive", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
    }()

    func testAudioOnChangesOutputButNotRandomStreams() {
        var loud = AudioFeatures.silent
        loud.level = 0.9
        let quiet = sequence(reactiveComposition, slots: 4, frames: 300)
        let driven = sequence(reactiveComposition, slots: 4, frames: 300, audio: loud)
        XCTAssertNotEqual(quiet, driven)
        XCTAssertGreaterThan(driven[100][0].brightness, quiet[100][0].brightness)

        var a = Composer2EngineState(), b = Composer2EngineState()
        let g = geometry(4)
        for i in 0..<300 {
            let t = Double(i) * 0.04
            _ = Composer2Engine.evaluate(reactiveComposition, time: t, geometry: g, state: &a)
            _ = Composer2Engine.evaluate(reactiveComposition, time: t, geometry: g, state: &b, audio: loud)
        }
        XCTAssertEqual(a.layers[0].events?.schedule, b.layers[0].events?.schedule)
        XCTAssertEqual(a.layers[0].events?.opportunityIndex, b.layers[0].events?.opportunityIndex)
    }

    func testSlotCountChangeMidRunKeepsCountsAndFinite() {
        var state = Composer2EngineState()
        let preset = Composer2PresetLibrary.thunderstorm
        for i in 0..<30 {
            let n = i < 15 ? 5 : 8
            let frames = Composer2Engine.evaluate(preset, time: Double(i) * 0.04, geometry: geometry(n), state: &state)
            XCTAssertEqual(frames.count, n)
            assertLegal(frames, "resize frame \(i)")
        }
    }

    func testMasterIntensityScalesBrightness() {
        var dim = Composer2PresetLibrary.christmasChase
        dim.master.intensity = 0.5
        for frame in sequence(dim, slots: 5, frames: 50) {
            for f in frame { XCTAssertLessThanOrEqual(f.brightness, 0.5 + 1e-9) }
        }
    }

    func testDisabledLayersYieldBlackButLegalFrames() {
        var c = Composer2PresetLibrary.auroraDrift
        for i in c.layers.indices { c.layers[i].enabled = false }
        let frames = sequence(c, slots: 4, frames: 5).last!
        XCTAssertEqual(frames.count, 4)
        assertLegal(frames, "disabled")
        for f in frames { XCTAssertEqual(f.brightness, 0) }
    }

    // MARK: Runtime + hook

    func testRuntimeHandlesBackwardsAndNaNTime() {
        let output = Composer2LiveOutput(composition: Composer2PresetLibrary.lavaLamp)
        output.setPreviewGeometry(geometry(4))
        _ = output.evaluate(time: 10)
        _ = output.evaluate(time: 10.04)
        let frames = output.evaluate(time: 2)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(output.lastRenderTime, 2)
        for layer in output.state.layers { XCTAssertEqual(layer.warpOffset, 0) }
        _ = output.evaluate(time: .nan)
        XCTAssertEqual(output.lastRenderTime, 2)
        assertLegal(output.lastFrames, "nan time")
    }

    func testHookIsHonouredByTheLegacyRenderer() {
        let output = Composer2LiveOutput(composition: Composer2PresetLibrary.christmasChase)
        let box = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        box.frameSource = output
        let ids = [3, 7, 11, 12]
        let frames = CompositionEngine.render(time: 1.25, channelIDs: ids, params: box)
        XCTAssertEqual(frames.map(\.channelID), ids)
        for f in frames { XCTAssert(f.brightness >= 0 && f.brightness <= 1 && f.x.isFinite && f.y.isFinite) }
        XCTAssertEqual(output.lastFrames.count, ids.count)
        // Not the legacy math: the same box without the source renders differently.
        let legacyBox = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        let legacy = CompositionEngine.render(time: 1.25, channelIDs: ids, params: legacyBox)
        XCTAssertNotEqual(frames.map { [$0.x, $0.y, $0.brightness] }, legacy.map { [$0.x, $0.y, $0.brightness] })
    }

    private final class WrongCountSource: CompositionFrameSource {
        func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
            [LightFrame(channelID: 0, x: 0.3, y: 0.3, brightness: 1)]
        }
    }

    func testHookFallsBackOnCountMismatch() {
        let preset = CompositionStore.builtInPresets[1]
        let hooked = CompositionParamBox(preset: preset)
        hooked.frameSource = WrongCountSource()
        let plain = CompositionParamBox(preset: preset)
        let a = CompositionEngine.render(time: 0.5, channelIDs: [0, 1, 2], params: hooked)
        let b = CompositionEngine.render(time: 0.5, channelIDs: [0, 1, 2], params: plain)
        XCTAssertEqual(a.map { [$0.x, $0.y, $0.brightness] }, b.map { [$0.x, $0.y, $0.brightness] })
    }

    func testPrimeWithSingleChannelRenders() {
        let output = Composer2LiveOutput(composition: Composer2PresetLibrary.thunderstorm)
        let box = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        box.frameSource = output
        let frames = CompositionEngine.render(time: 0, channelIDs: [0], params: box)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].channelID, 0)
    }

    func testGeometryRebuildsWhenBoxArraysChange() {
        let output = Composer2LiveOutput(composition: Composer2PresetLibrary.auroraDrift)
        let box = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        box.frameSource = output
        let five = geometry(5)
        box.radialPositions = five.radial
        box.angularPositions = five.angular
        _ = CompositionEngine.render(time: 0.1, channelIDs: Array(0..<5), params: box)
        XCTAssertEqual(output.geometry.count, 5)
        XCTAssertTrue(output.geometry.hasSpatialData)
        box.radialPositions = []
        box.angularPositions = []
        _ = CompositionEngine.render(time: 0.2, channelIDs: Array(0..<3), params: box)
        XCTAssertEqual(output.geometry.count, 3)
        XCTAssertFalse(output.geometry.hasSpatialData)
    }

    func testMirroredReactionSourceFollowsTheComposition() {
        let plain = Composer2LiveOutput(composition: Composer2PresetLibrary.lavaLamp)
        XCTAssertEqual(plain.mirroredReactionSource(), .none)
        let reactive = Composer2LiveOutput(composition: reactiveComposition)
        XCTAssertEqual(reactive.mirroredReactionSource(), .micAmplitude)
        var beat = reactiveComposition
        beat.layers[0].audio.source = .beat
        XCTAssertEqual(Composer2LiveOutput(composition: beat).mirroredReactionSource(), .beat)
    }

    func testEventCapLimitsFlashes() {
        var spec = Composer2EventSpec(timing: .fixed, interval: 1, probability: 1, burstMin: 1, burstMax: 1,
                                      durationMin: 0.5, durationMax: 0.5, decaySeconds: 0.2, intensityMin: 1, intensityMax: 1)
        spec.targeting = .all
        let layer = Composer2Layer(name: "Flash", blend: .addLighten, color: .solid(.d65),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0), events: spec)
        let c = Composer2Composition(name: "Flash", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let output = Composer2LiveOutput(composition: c)
        output.setPreviewGeometry(geometry(3))
        output.eventCap = 0.3
        var peak = 0.0
        for i in 0..<100 {
            for f in output.evaluate(time: Double(i) * 0.04) { peak = max(peak, f.brightness) }
        }
        XCTAssertGreaterThan(peak, 0.2)
        XCTAssertLessThanOrEqual(peak, 0.3 + 1e-9)
    }
}
