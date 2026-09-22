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
        layer.audio = Composer2AudioModulation(source: .amplitude, brightnessMode: .dimWhenQuiet,
                                               sensitivity: 0.8, threshold: 0,
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

    func testPunchModeAddsLightOnSoundAndLeavesQuietUntouched() {
        var c = reactiveComposition
        c.layers[0].audio.brightnessMode = .punch
        c.layers[0].rhythm = Composer2Rhythm(shape: .steady, maxBrightness: 0.4)
        var loud = AudioFeatures.silent
        loud.level = 0.9
        let quiet = sequence(c, slots: 3, frames: 40)
        let driven = sequence(c, slots: 3, frames: 40, audio: loud)
        XCTAssertEqual(quiet[30][0].brightness, 0.4, accuracy: 1e-9, "quiet keeps the authored level")
        XCTAssertGreaterThan(driven[30][0].brightness, 0.6, "sound adds light")
        XCTAssertLessThanOrEqual(driven[30][0].brightness, 1)
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


    // MARK: - v2.2 regressions

    private func single(_ layer: Composer2Layer, master: Composer2MasterControls? = nil) -> Composer2Composition {
        Composer2Composition(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C2C2")!, name: "Test",
                             createdAt: Date(timeIntervalSince1970: 0), master: master, layers: [layer])
    }

    private func hue(_ f: Composer2Frame) -> Double {
        Composer2ColorMath.lab(fromXY: Composer2XY(x: f.x, y: f.y)).hue
    }

    /// Evolving speed jitter multiplied ABSOLUTE time, so the phase rate grew
    /// with how long the look had played. After an hour the colour must
    /// still move at the authored pace.
    func testEvolvingSpeedJitterNeverRunsAwayOverAnHour() {
        let wheel = (0..<8).map { i -> Composer2XY in
            let p = HueColorUtils.xyFrom(hue: Double(i) / 8, saturation: 1, brightness: 1)
            let c = HueColorUtils.clampXYToGamut(x: p.x, y: p.y, gamut: .c)
            return Composer2XY(x: c.x, y: c.y)
        }
        var variation = Composer2Variation.wild
        variation.perLightPhase = 0; variation.paletteDrift = 0; variation.brightnessVariation = 0
        variation.spatialRandomness = 0
        let layer = Composer2Layer(color: .stops(wheel), motion: Composer2Motion(kind: .flow, periodSeconds: 10, spread: 0),
                                   rhythm: Composer2Rhythm(shape: .steady), variation: variation)
        let c = single(layer)
        func meanStep(from start: Double) -> Double {
            var state = Composer2EngineState()
            var previous: Double?
            var total = 0.0
            let g = geometry(4)
            for i in 0..<750 {
                let f = Composer2Engine.evaluate(c, time: start + Double(i) * 0.04, geometry: g, state: &state)[2]
                let h = hue(f)
                if let p = previous {
                    var d = abs(h - p)
                    if d > .pi { d = 2 * .pi - d }
                    total += d
                }
                previous = h
            }
            return total / 749
        }
        let early = meanStep(from: 5)
        let late = meanStep(from: 3600)
        XCTAssertLessThan(late, early * 2 + 0.02, "an hour in, the look runs at its authored pace")
        XCTAssertLessThan(late, 0.12, "no runaway speed")
    }

    /// Energy 0 is labelled "Exact": it must reach evolving layers and drift too.
    func testEnergyZeroMakesEveryLayerExact() {
        var quiet = Composer2PresetLibrary.auroraDrift
        quiet.master.variation = 0
        var exact = Composer2PresetLibrary.auroraDrift
        for i in exact.layers.indices { exact.layers[i].variation = Composer2Variation.exact }
        XCTAssertEqual(sequence(quiet, slots: 6, frames: 120), sequence(exact, slots: 6, frames: 120))
    }

    func testPaletteDriftMovesColoursPerLight() {
        var color = Composer2ColorSource.stops([Composer2XY(x: 0.64, y: 0.33), Composer2XY(x: 0.17, y: 0.7), Composer2XY(x: 0.15, y: 0.06)])
        color.distribution = .uniform
        let still = single(Composer2Layer(color: color, motion: Composer2Motion(kind: .static), rhythm: Composer2Rhythm(shape: .steady)))
        color.drift = 1
        let drifting = single(Composer2Layer(color: color, motion: Composer2Motion(kind: .static), rhythm: Composer2Rhythm(shape: .steady)))
        func spread(_ c: Composer2Composition) -> Double {
            var worst = 0.0
            for frames in sequence(c, slots: 6, frames: 300, dt: 0.2) {
                for a in frames { for b in frames { worst = max(worst, hypot(a.x - b.x, a.y - b.y)) } }
            }
            return worst
        }
        XCTAssertEqual(spread(still), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(spread(drifting), 0.01, "the palette's Drift control reaches the lights")
    }

    /// Stepping the palette on a hit used to consume the onset the event
    /// trigger needed, so "Trigger events on hits" never fired.
    func testOnsetTriggersEventsWhileAlsoSteppingThePalette() {
        var layer = Composer2Layer(color: .stops([Composer2XY(x: 0.64, y: 0.33), Composer2XY(x: 0.15, y: 0.06)]),
                                   motion: Composer2Motion(kind: .static), rhythm: Composer2Rhythm(shape: .steady))
        layer.audio = Composer2AudioModulation(source: .onset, targets: [.palettePosition], triggerEventsOnOnset: true)
        layer.events = Composer2EventSpec(timing: .fixed, interval: 3600, probability: 1, burstMin: 1, burstMax: 1)
        let c = single(layer)
        var state = Composer2EngineState()
        let g = geometry(3)
        var audio = AudioFeatures()
        for i in 0..<50 {
            let t = Double(i) * 0.04
            if i == 25 { audio.lastOnsetAt = 100 + t }
            _ = Composer2Engine.evaluate(c, time: t, geometry: g, state: &state, audio: audio, hostNow: 100 + t)
        }
        XCTAssertGreaterThan(state.layers[0].paletteStepPhase, 0, "the palette stepped")
        XCTAssertEqual(state.layers[0].events?.firedCount, 1, "and the same hit fired the event")
    }

    /// A re-tapped tempo re-anchors the beat index near 0; stepping must
    /// continue from there instead of freezing until the old count returns.
    func testBeatColourSteppingSurvivesAReanchoredClock() {
        var layer = Composer2Layer(color: .stops([Composer2XY(x: 0.64, y: 0.33), Composer2XY(x: 0.15, y: 0.06)]),
                                   motion: Composer2Motion(kind: .static), rhythm: Composer2Rhythm(shape: .steady))
        layer.audio = Composer2AudioModulation(source: .beat, targets: [.palettePosition], quantizeBeats: 1, paletteStep: 0.25)
        let c = single(layer)
        var state = Composer2EngineState()
        let g = geometry(2)
        var beat = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4)
        var t = 0.0
        while t < 60 {   // 120 beats
            _ = Composer2Engine.evaluate(c, time: t, geometry: g, state: &state, beat: beat, hostNow: 1000 + t)
            t += 0.05
        }
        beat.beatEpoch = 1000 + t   // Tap tempo: beat 0 is now
        let before = state.layers[0].paletteStepPhase
        var changes = 0
        var last = before
        for _ in 0..<80 {   // 4 s = 8 beats
            _ = Composer2Engine.evaluate(c, time: t, geometry: g, state: &state, beat: beat, hostNow: 1000 + t)
            if state.layers[0].paletteStepPhase != last { changes += 1; last = state.layers[0].paletteStepPhase }
            t += 0.05
        }
        XCTAssertGreaterThanOrEqual(changes, 6, "colour keeps stepping on the re-anchored beat")
    }

    /// Save as new (and saving a built-in) must play exactly what was
    /// auditioned — random halves, event timing and targets included.
    func testDuplicatePlaysTheSameLook() {
        for preset in [Composer2PresetLibrary.hauntedHouse, Composer2PresetLibrary.thunderstorm, Composer2PresetLibrary.lavaLamp] {
            let copy = preset.duplicated(name: "Mine", at: Date(timeIntervalSince1970: 9))
            XCTAssertNotEqual(copy.id, preset.id)
            XCTAssertEqual(sequence(copy, slots: 8, frames: 750, dt: 0.1), sequence(preset, slots: 8, frames: 750, dt: 0.1),
                           "\(preset.name) changed when saved as new")
        }
    }

    func testChaseTailFollowsTheHeadOnTheReturnSweep() {
        let chase = Composer2Motion(kind: .chase, periodSeconds: 4, travelWidth: 0.3, edge: .bounce)
        // t = 5 s: the head is at 0.75, travelling back toward 0.
        let passed = chase.sample(slot: 0, position: 0.85, cross: 0.5, time: 5, seed: 1).weight
        let ahead = chase.sample(slot: 1, position: 0.6, cross: 0.5, time: 5, seed: 1).weight
        XCTAssertGreaterThan(passed, ahead, "the tail trails the head, it does not lead it")
        // …and on the outward sweep (t = 1 s, head at 0.25 moving up) the other way round.
        let passedOut = chase.sample(slot: 0, position: 0.15, cross: 0.5, time: 1, seed: 1).weight
        let aheadOut = chase.sample(slot: 1, position: 0.4, cross: 0.5, time: 1, seed: 1).weight
        XCTAssertGreaterThan(passedOut, aheadOut)
    }

    func testReplaceOverBlackKeepsTheLayersColour() {
        let red = Composer2ColorMath.lab(fromXY: Composer2XY(x: 0.64, y: 0.33))
        var acc = Composer2Blend.Accum()
        Composer2Blend.composite(&acc, lab: red, brightness: 1, coverage: 0.5, mode: .replace)
        XCTAssertEqual(acc.brightness, 0.5, accuracy: 1e-9)
        let xy = Composer2ColorMath.xy(fromLab: acc.lab)
        XCTAssertLessThan(hypot(xy.x - 0.64, xy.y - 0.33), 0.02, "half-bright RED, not pink")
    }

    /// Dragging a delay down must take effect now, not after the opportunity
    /// already drawn from the old (long) delay.
    func testEditingTheEventDelayReArmsTheSchedule() {
        var layer = Composer2Layer(motion: Composer2Motion(kind: .static), rhythm: Composer2Rhythm(shape: .steady))
        layer.events = Composer2EventSpec(timing: .fixed, interval: 600, probability: 1, burstMin: 1, burstMax: 1)
        var c = single(layer)
        var state = Composer2EngineState()
        let g = geometry(3)
        var t = 0.0
        while t < 2 { _ = Composer2Engine.evaluate(c, time: t, geometry: g, state: &state); t += 0.04 }
        XCTAssertEqual(state.layers[0].events?.firedCount ?? 0, 0)
        c.layers[0].events?.interval = 1
        while t < 5 { _ = Composer2Engine.evaluate(c, time: t, geometry: g, state: &state); t += 0.04 }
        XCTAssertGreaterThanOrEqual(state.layers[0].events?.firedCount ?? 0, 1)
    }

    /// Master speed ×4 must not push a motion already at the flash-budget
    /// floor any faster.
    func testMasterSpeedNeverPushesAFloorMotionPastTheBudget() {
        let layer = Composer2Layer(motion: Composer2Motion(kind: .chase, periodSeconds: Composer2Motion.minimumPeriod, steps: 3),
                                   rhythm: Composer2Rhythm(shape: .steady))
        let c = single(layer, master: Composer2MasterControls(speed: 4, seed: 7))
        var state = Composer2EngineState()
        let g = geometry(4)
        for i in 0..<100 { _ = Composer2Engine.evaluate(c, time: Double(i) * 0.04, geometry: g, state: &state) }
        XCTAssertEqual(state.layers[0].warpOffset, 0, accuracy: 1e-9, "no speed-up past the floor")
        // A slow motion still takes the full ×4.
        let slow = single(Composer2Layer(motion: Composer2Motion(kind: .flow, periodSeconds: 20), rhythm: Composer2Rhythm(shape: .steady)),
                          master: Composer2MasterControls(speed: 4, seed: 7))
        var slowState = Composer2EngineState()
        for i in 0..<101 { _ = Composer2Engine.evaluate(slow, time: Double(i) * 0.04, geometry: g, state: &slowState) }
        XCTAssertEqual(slowState.layers[0].warpOffset, 4 * 3, accuracy: 1e-6)
    }

    /// "1 beat" at 300 BPM is a 0.2 s pulse; the lock doubles the cycle until
    /// it is legal.
    func testBeatLockedRhythmObeysTheFlashFloor() {
        let layer = Composer2Layer(motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .pulse, depth: 1, duty: 0.3, quantizeBeats: 1))
        let c = single(layer)
        var state = Composer2EngineState()
        let g = geometry(1)
        let beat = BeatSnapshot(bpm: 300, beatEpoch: 0, beatsPerBar: 4)
        var values: [Double] = []
        for i in 0..<500 {
            let t = Double(i) * 0.01
            values.append(Composer2Engine.evaluate(c, time: t, geometry: g, state: &state, beat: beat, hostNow: 10 + t)[0].brightness)
        }
        var rises: [Int] = []
        for i in 1..<values.count where values[i - 1] < 0.5 && values[i] >= 0.5 { rises.append(i) }
        XCTAssertGreaterThan(rises.count, 3)
        for (a, b) in zip(rises, rises.dropFirst()) {
            XCTAssertGreaterThanOrEqual(Double(b - a) * 0.01, BeatMath.FlashSafety.minOnsetLedgerPeriod - 0.011)
        }
    }

    func testCyclingPaletteWithExplicitPositionsHasNoSeam() {
        let source = Composer2ColorSource(stops: [Composer2PaletteStop(x: 0.64, y: 0.33, position: 0.25),
                                                  Composer2PaletteStop(x: 0.15, y: 0.06, position: 0.75)],
                                          interpolation: .hueArc, cycle: true)
        let palette = Composer2CompiledPalette(source)
        let before = palette.sampleXY(0.999)
        let after = palette.sampleXY(0.0)
        XCTAssertLessThan(hypot(before.x - after.x, before.y - after.y), 0.01, "continuous across the wrap")
    }

    func testLegacyChaseImportKeepsItsStepsAndTail() {
        var preset = CompositionStore.builtInPresets[0]
        preset.motion.pattern = .chase
        preset.motion.offset = 0
        preset.motion.spread = 40
        let layer = Composer2LegacyImport.layer(from: preset)
        XCTAssertEqual(layer.motion.steps, 12, "the head steps like the legacy chase; the colour is not frozen")
        XCTAssertEqual(layer.motion.travelWidth, 0.4, accuracy: 1e-9, "the legacy tail, mapped once")
        preset.reaction.motionBeatsPerCycle = 4
        let locked = Composer2LegacyImport.layer(from: preset)
        XCTAssertEqual(locked.rhythm.quantizeBeats, 0, "the brightness rhythm is not beat-locked by a motion lock")
        XCTAssertEqual(locked.motion.periodSeconds, 2, accuracy: 1e-9)
    }
}
