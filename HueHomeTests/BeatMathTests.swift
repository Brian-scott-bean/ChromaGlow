// BeatMathTests.swift
// HueHome Pro — Unit Tests
//
// Round 3 Universal Beat Panel: BeatBinding (snapping, migration-safe
// decode) and BeatMath (cycle phase/index/boundary, WCAG flash cap).
// Pure math — deterministic, no clocks, no audio.

import XCTest
@testable import HueHome

final class BeatMathTests: XCTestCase {

    // 120 BPM, epoch at t=0, 4/4 — beat interval 0.5 s.
    private let snap120 = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4)

    // MARK: - BeatBinding snapping / clamping

    func testSnappedStepPicksNearestAllowedValue() {
        XCTAssertEqual(BeatBinding.snappedStep(0.3), 0.25)
        XCTAssertEqual(BeatBinding.snappedStep(0.7), 0.5)
        XCTAssertEqual(BeatBinding.snappedStep(3.1), 4)
        XCTAssertEqual(BeatBinding.snappedStep(37), 8)
        XCTAssertEqual(BeatBinding.snappedStep(-5), 0.25)
        XCTAssertEqual(BeatBinding.snappedStep(.nan), 1)
    }

    func testInitSnapsAndClamps() {
        let b = BeatBinding(mode: .beatLocked, beatsPerCycle: 3.3, phaseOffsetBeats: 99)
        XCTAssertEqual(b.beatsPerCycle, 4)
        XCTAssertEqual(b.phaseOffsetBeats, 8)
        XCTAssertTrue(b.isActive)
        XCTAssertFalse(BeatBinding.off.isActive)
    }

    // MARK: - Migration-safe decode

    func testDecodeEmptyObjectYieldsDefaults() throws {
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data("{}".utf8))
        XCTAssertEqual(b, .off)
    }

    func testDecodeWildValuesSelfSanitize() throws {
        let json = #"{"mode":"beatLocked","beatsPerCycle":37,"phaseOffsetBeats":-99}"#
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data(json.utf8))
        XCTAssertEqual(b.mode, .beatLocked)
        XCTAssertEqual(b.beatsPerCycle, 8)
        XCTAssertEqual(b.phaseOffsetBeats, -8)
    }

    func testDecodeUnknownModeFallsBackToOff() throws {
        let json = #"{"mode":"laserRave","beatsPerCycle":2}"#
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data(json.utf8))
        XCTAssertEqual(b.mode, .off)
        XCTAssertEqual(b.beatsPerCycle, 2)
    }

    func testPreRound3PresetJSONDecodesWithNilBeat() throws {
        // A preset exactly as persisted before the `beat` field existed
        // (synthesized Codable always wrote all six collections).
        let json = #"""
        {"id":"p1","name":"Old","baseEffectID":"strobe",
         "sliders":{"speed":5},"toggles":{},"segmented":{},
         "durations":{},"colors":{},"palettes":{}}
        """#
        let p = try JSONDecoder().decode(SavedEffectPreset.self, from: Data(json.utf8))
        XCTAssertNil(p.beat)
        XCTAssertEqual(p.sliders["speed"], 5)
    }

    func testPresetBeatRoundTrips() throws {
        var p = SavedEffectPreset(name: "New", baseEffectID: "strobe")
        p.beat = BeatBinding(mode: .beatLocked, beatsPerCycle: 2, phaseOffsetBeats: 0.5)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SavedEffectPreset.self, from: data)
        XCTAssertEqual(back.beat, p.beat)
    }

    // MARK: - WCAG flash cap

    func testWcagCapSteps174BpmHalfBeatUpToOne() {
        // 174 BPM × ½-beat = 5.8 Hz > 3 Hz → must step to ×1 (2.9 Hz).
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.5, bpm: 174), 1)
    }

    func testWcagCapAllowsSafeRequests() {
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: 120), 1)   // 2 Hz
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.5, bpm: 60), 0.5) // 2 Hz
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 4, bpm: 174), 4)
    }

    func testWcagCapQuarterBeatAt120Bpm() {
        // 120 BPM × ¼ = 8 Hz → ½ = 4 Hz → 1 = 2 Hz. First safe step is 1.
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.25, bpm: 120), 1)
    }

    func testWcagCapNoClockPassesThrough() {
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.25, bpm: 0), 0.25)
    }

    // MARK: - Cycle phase / index / boundary

    func testCyclePhaseOneBeatCycle() {
        // interval 0.5 s → at t=0.25 we are half-way through beat 0.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.25, snapshot: snap120, beatsPerCycle: 1),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.5, snapshot: snap120, beatsPerCycle: 1),
                       0.0, accuracy: 1e-9)
    }

    func testCyclePhaseTwoBeatCycle() {
        // 2-beat cycle = 1.0 s → t=0.5 is half-way.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.5, snapshot: snap120, beatsPerCycle: 2),
                       0.5, accuracy: 1e-9)
    }

    func testPhaseOffsetShiftsTheGrid() {
        // Offset ½ beat: the cycle boundary moves from t=0 to t=0.25.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.25, snapshot: snap120,
                                           beatsPerCycle: 1, phaseOffsetBeats: 0.5),
                       0.0, accuracy: 1e-9)
    }

    func testCyclePhaseNegativeTimeWraps() {
        let phase = BeatMath.cyclePhase(at: -0.1, snapshot: snap120, beatsPerCycle: 1)
        XCTAssertGreaterThanOrEqual(phase, 0)
        XCTAssertLessThan(phase, 1)
        XCTAssertEqual(phase, 0.8, accuracy: 1e-9)   // -0.1/0.5 = -0.2 → 0.8
    }

    func testCycleIndexIncrementsAtBoundary() {
        XCTAssertEqual(BeatMath.cycleIndex(at: 0.49, snapshot: snap120, beatsPerCycle: 1), 0)
        XCTAssertEqual(BeatMath.cycleIndex(at: 0.51, snapshot: snap120, beatsPerCycle: 1), 1)
        XCTAssertEqual(BeatMath.cycleIndex(at: -0.1, snapshot: snap120, beatsPerCycle: 1), -1)
    }

    func testNextCycleBoundaryIsStrictlyAfterT() {
        // bar-length cycles (4 beats = 2 s): from t=0.1 the next bar starts at 2.0.
        let next = BeatMath.nextCycleBoundary(after: 0.1, snapshot: snap120, beatsPerCycle: 4)
        XCTAssertEqual(next, 2.0, accuracy: 1e-9)
        XCTAssertGreaterThan(next, 0.1)
        // One-beat cycles: from t=0.5 exactly, the next boundary is 1.0.
        let n2 = BeatMath.nextCycleBoundary(after: 0.5, snapshot: snap120, beatsPerCycle: 1)
        XCTAssertEqual(n2, 1.0, accuracy: 1e-9)
    }

    // MARK: - Free-running semantics

    func testFreeRunningWhenModeOff() {
        let binding = BeatBinding.off
        XCTAssertTrue(BeatMath.isFreeRunning(binding, snapshot: snap120))
        XCTAssertNil(BeatMath.cyclePhase(binding, snapshot: snap120, at: 1))
    }

    func testFreeRunningWhenNoClock() {
        let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1)
        XCTAssertTrue(BeatMath.isFreeRunning(binding, snapshot: .none))
        XCTAssertNil(BeatMath.cyclePhase(binding, snapshot: .none, at: 1))
    }

    func testBoundBindingReturnsPhase() {
        let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1)
        XCTAssertEqual(BeatMath.cyclePhase(binding, snapshot: snap120, at: 0.25) ?? -1,
                       0.5, accuracy: 1e-9)
    }

    // MARK: - BeatClock.setBeatsPerBar

    @MainActor
    func testSetBeatsPerBarClampsAndPublishes() {
        let clock = BeatClock()
        clock.setBPM(100, now: 10)
        clock.setBeatsPerBar(3)
        XCTAssertEqual(clock.beatsPerBar, 3)
        clock.setBeatsPerBar(99)
        XCTAssertEqual(clock.beatsPerBar, 12)
        clock.setBeatsPerBar(0)
        XCTAssertEqual(clock.beatsPerBar, 1)
    }
}

// MARK: - CompositionMixerTests (Round 3 C: Perform)

final class CompositionMixerTests: XCTestCase {

    private let snap120 = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4)
    private let channels: [UInt8] = [0, 1, 2]

    private func box(hueShift: Double = 0) -> CompositionParamBox {
        let box = CompositionParamBox(
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.palette.hueShift = hueShift
        return box
    }

    private func assertFramesEqual(_ a: [LightFrame], _ b: [LightFrame],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (fa, fb) in zip(a, b) {
            XCTAssertEqual(fa.x, fb.x, accuracy: 1e-12, file: file, line: line)
            XCTAssertEqual(fa.y, fb.y, accuracy: 1e-12, file: file, line: line)
            XCTAssertEqual(fa.brightness, fb.brightness, accuracy: 1e-12, file: file, line: line)
        }
    }

    func testCrossfadeEndpointsMatchPureDeckRenders() {
        let deckA = box()
        let deckB = box(hueShift: 90)
        let mix = PerformanceMixBox(deckA: deckA)
        mix.deckB = deckB

        mix.crossfade = 0
        assertFramesEqual(
            CompositionMixer.renderMixed(time: 1.0, channelIDs: channels, mix: mix),
            CompositionEngine.render(time: 1.0, channelIDs: channels, params: deckA))

        mix.crossfade = 1
        assertFramesEqual(
            CompositionMixer.renderMixed(time: 1.0, channelIDs: channels, mix: mix),
            CompositionEngine.render(time: 1.0, channelIDs: channels, params: deckB))
    }

    func testBlackoutPunchZeroesBrightnessWhileHeld() {
        let mix = PerformanceMixBox(deckA: box())
        mix.engagePunch(.blackout)
        let frames = CompositionMixer.renderMixed(time: 1, channelIDs: channels, mix: mix,
                                                  hostNow: 100)
        XCTAssertTrue(frames.allSatisfy { $0.brightness < 1e-9 })
    }

    func testWhiteBurstDrivesD65FullBrightness() {
        let mix = PerformanceMixBox(deckA: box())
        mix.engagePunch(.whiteBurst)
        let frames = CompositionMixer.renderMixed(time: 1, channelIDs: channels, mix: mix,
                                                  hostNow: 100)
        for frame in frames {
            XCTAssertEqual(frame.x, 0.3127, accuracy: 1e-6)
            XCTAssertEqual(frame.y, 0.3290, accuracy: 1e-6)
            XCTAssertEqual(frame.brightness, 1.0, accuracy: 1e-9)
        }
    }

    func testPunchReleaseRampsOverTwoHundredMs() {
        let mix = PerformanceMixBox(deckA: box())
        mix.engagePunch(.blackout)
        mix.releasePunch(hostNow: 100)
        XCTAssertEqual(CompositionMixer.punchStrength(mix: mix, hostNow: 100.1),
                       0.5, accuracy: 1e-9)
        // Past the ramp: strength 0 and the punch self-clears.
        XCTAssertEqual(CompositionMixer.punchStrength(mix: mix, hostNow: 100.3), 0)
        XCTAssertNil(mix.punch)
    }

    func testStrobeNeverExceedsThreeHz() {
        // 300 BPM = 5 Hz beat rate — the strobe must clamp to the 3 Hz cap
        // (free-running phase), giving a 1/3 s period.
        let fast = BeatSnapshot(bpm: 300, beatEpoch: 0, beatsPerBar: 4)
        let mix = PerformanceMixBox(deckA: box())
        mix.engagePunch(.strobe)

        func isOn(at t: Double) -> Bool {
            CompositionMixer.renderMixed(time: 1, channelIDs: [0], mix: mix,
                                         beat: fast, hostNow: t)[0].brightness > 0.5
        }
        // 3 Hz: ON for the first half of each 1/3 s cycle.
        XCTAssertTrue(isOn(at: 90.02))          // phase 0.06
        XCTAssertFalse(isOn(at: 90.02 + 1.0/6)) // half a cycle later → off
        XCTAssertTrue(isOn(at: 90.02 + 1.0/3))  // full cycle later → on again
    }

    func testStrobeFollowsBeatWhenUnderCap() {
        // 120 BPM (2 Hz ≤ 3 Hz): flashes ride the beat grid exactly.
        let mix = PerformanceMixBox(deckA: box())
        mix.engagePunch(.strobe)
        let on = CompositionMixer.renderMixed(time: 1, channelIDs: [0], mix: mix,
                                              beat: snap120, hostNow: 0.1)[0]  // beatPhase 0.2
        let off = CompositionMixer.renderMixed(time: 1, channelIDs: [0], mix: mix,
                                               beat: snap120, hostNow: 0.4)[0] // beatPhase 0.8
        XCTAssertGreaterThan(on.brightness, 0.5)
        XCTAssertLessThan(off.brightness, 0.5)
    }

    func testMasterFaderScalesPostBlend() {
        let deckA = box()
        let mix = PerformanceMixBox(deckA: deckA)
        mix.masterIntensity = 0.5
        let pure = CompositionEngine.render(time: 1, channelIDs: channels, params: deckA)
        let mixed = CompositionMixer.renderMixed(time: 1, channelIDs: channels, mix: mix)
        for (p, m) in zip(pure, mixed) {
            XCTAssertEqual(m.brightness, p.brightness * 0.5, accuracy: 1e-9)
        }
    }

    // ── Sequencer model (Round 3 D) ──

    func testSequenceStepDecodesFromEmptyObject() throws {
        let step = try JSONDecoder().decode(CompositionSequence.Step.self,
                                            from: Data("{}".utf8))
        XCTAssertEqual(step.bars, 8)
        XCTAssertEqual(step.crossfadeBeats, 4)
        let seq = try JSONDecoder().decode(CompositionSequence.self,
                                           from: Data("{}".utf8))
        XCTAssertTrue(seq.steps.isEmpty)
        XCTAssertTrue(seq.loops)
    }

    func testPresetSequenceRoundTripsAndOldPresetsDecodeNil() throws {
        var preset = CompositionPreset(
            id: UUID(), name: "Seq", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .myCreations, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(), updatedAt: Date())
        preset.sequence = CompositionSequence(
            steps: [CompositionSequence.Step(name: "Golden Hour", bars: 4, crossfadeBeats: 2)],
            loops: false)
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(CompositionPreset.self, from: data)
        XCTAssertEqual(back.sequence?.steps.first?.name, "Golden Hour")
        XCTAssertEqual(back.sequence?.loops, false)

        // Pre-sequencer JSON (id only — M-13 minimum) decodes with nil.
        let old = try JSONDecoder().decode(
            CompositionPreset.self,
            from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        XCTAssertNil(old.sequence)
    }

    /// R4-7 sequence-persistence UI: preset.sequence survives a full
    /// CompositionStore save → reload cycle (what "Save with composition"
    /// followed by an app relaunch exercises).
    func testSequencePersistsThroughStoreSaveAndReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("compositions.json")

        let store = CompositionStore(fileURL: url)
        var preset = CompositionPreset(
            id: UUID(), name: "Seq Home", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .myCreations, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(), updatedAt: Date())
        preset.sequence = CompositionSequence(
            steps: [
                CompositionSequence.Step(name: "Golden Hour", bars: 4, crossfadeBeats: 2),
                CompositionSequence.Step(name: "Bass Drop", bars: 16, crossfadeBeats: 8),
            ],
            loops: false)
        store.save(preset)

        // Fresh store = relaunch.
        let reloaded = CompositionStore(fileURL: url)
        let restored = try XCTUnwrap(reloaded.presets.first(where: { $0.id == preset.id }))
        let sequence = try XCTUnwrap(restored.sequence)
        XCTAssertEqual(sequence.steps.map(\.name), ["Golden Hour", "Bass Drop"])
        XCTAssertEqual(sequence.steps.map(\.bars), [4, 16])
        XCTAssertEqual(sequence.steps.map(\.crossfadeBeats), [2, 8])
        XCTAssertFalse(sequence.loops)

        // Clearing the steps clears the field on the next save (nil-additive).
        var cleared = restored
        cleared.sequence = nil
        reloaded.save(cleared)
        let final = CompositionStore(fileURL: url)
        XCTAssertNil(final.presets.first(where: { $0.id == preset.id })?.sequence)
    }

    func testAutoFadeBeatsVariantWithoutClockLandsInstantly() {
        let mix = PerformanceMixBox(deckA: box())
        mix.deckB = box(hueShift: 90)
        mix.startAutoFade(beats: 4, beat: .none, hostNow: 0)
        XCTAssertNil(mix.autoFade)
        XCTAssertEqual(mix.crossfade, 1.0)   // lands rather than hangs
    }

    func testAutoFadeIsBeatExactAndSelfCompletes() {
        let mix = PerformanceMixBox(deckA: box())
        mix.deckB = box(hueShift: 90)
        // 1 bar at 120 BPM 4/4 = 4 beats = 2.0 s, starting at host t=10.
        mix.startAutoFade(bars: 1, beat: snap120, hostNow: 10)

        _ = CompositionMixer.renderMixed(time: 1, channelIDs: [0], mix: mix,
                                         beat: snap120, hostNow: 11)   // half-way
        XCTAssertEqual(mix.crossfade, 0.5, accuracy: 1e-6)
        XCTAssertNotNil(mix.autoFade)

        _ = CompositionMixer.renderMixed(time: 1, channelIDs: [0], mix: mix,
                                         beat: snap120, hostNow: 12.1) // past the bar
        XCTAssertEqual(mix.crossfade, 1.0, accuracy: 1e-9)
        XCTAssertNil(mix.autoFade)
    }
}
