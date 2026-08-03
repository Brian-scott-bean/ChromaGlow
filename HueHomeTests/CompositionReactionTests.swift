// CompositionReactionTests.swift
// HueHome Pro — Unit Tests
//
// Phase-2 render/reaction upgrade: beat-locked reaction targets (.color /
// .speed / punch brightness), the previously-dead knobs (smoothing, spread,
// randomize) now doing real work, the new motion patterns, and migration
// safety for every additive Codable field.

import XCTest
@testable import HueHome

final class CompositionReactionTests: XCTestCase {

    // ──────────────────────────────────────────────
    // MARK: - Migration safety (additive fields)
    // ──────────────────────────────────────────────

    func testLegacyReactionJSONDecodesWithNewDefaults() throws {
        let legacy = #"{"source":"mic_bass","sensitivity":50,"targets":["brightness"],"smoothing":30,"intensity":70,"threshold":10}"#
        let r = try JSONDecoder().decode(ReactionConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(r.source, .micBass)
        XCTAssertEqual(r.quantizeBeats, 1)
        XCTAssertEqual(r.colorStepPerTrigger, 0.25)
        XCTAssertEqual(r.motionBeatsPerCycle, 0)
        XCTAssertEqual(r.punchDecay, 40)
    }

    func testUnknownReactionSourceFallsBackToNone() throws {
        let futuristic = #"{"source":"quantum_flux"}"#
        let r = try JSONDecoder().decode(ReactionConfig.self, from: Data(futuristic.utf8))
        XCTAssertEqual(r.source, .none, "an unknown source raw value must never drop the preset")
    }

    func testNewPatternDecodesAndUnknownFallsBackToCascade() throws {
        let chase = try JSONDecoder().decode(MotionConfig.self, from: Data(#"{"pattern":"chase"}"#.utf8))
        XCTAssertEqual(chase.pattern, .chase)
        let unknown = try JSONDecoder().decode(MotionConfig.self, from: Data(#"{"pattern":"zigzag"}"#.utf8))
        XCTAssertEqual(unknown.pattern, .cascade)
    }

    func testOldSchemaPresetDecodesIntact() throws {
        let old = """
        {"id":"E1F5D3A0-0000-0000-0000-000000000001","name":"Old",
         "palette":{"mode":"gradient"},"motion":{"pattern":"wave","speed":40},
         "envelope":{"shape":"breathe","bpm":60},
         "reaction":{"source":"tap_tempo"}}
        """
        let p = try JSONDecoder().decode(CompositionPreset.self, from: Data(old.utf8))
        XCTAssertEqual(p.motion.pattern, .wave)
        XCTAssertEqual(p.reaction.source, .tapTempo)
        XCTAssertEqual(p.reaction.quantizeBeats, 1)
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func makeBox(
        pattern: MotionConfig.Pattern = .cascade,
        spread: Double = 100,
        randomize: Bool = false,
        reaction: ReactionConfig = ReactionConfig()
    ) -> CompositionParamBox {
        let box = CompositionParamBox(
            palette: PaletteConfig(mode: .spectrum, randomize: randomize),
            motion: MotionConfig(pattern: pattern, speed: 50, spread: spread),
            envelope: EnvelopeConfig(shape: .steady, maxBrightness: 100),
            reaction: reaction
        )
        box.spatialPositions = [0.0, 0.5, 1.0]
        box.targetSpatialPositions = box.spatialPositions
        return box
    }

    private let channels: [Int] = [0, 1, 2]

    // ──────────────────────────────────────────────
    // MARK: - spread (previously dead)
    // ──────────────────────────────────────────────

    func testSpread100KeepsFullWashBrightness() {
        // Back-compat: at spread=100 the motion weight is 1 everywhere, so
        // brightness equals the plain envelope value (legacy behavior).
        let box = makeBox(pattern: .cascade, spread: 100)
        let frames = CompositionEngine.render(time: 0.7, channelIDs: channels, params: box)
        for f in frames {
            XCTAssertEqual(f.brightness, 1.0, accuracy: 0.001,
                           "spread=100 must reproduce the legacy full-wash brightness")
        }
    }

    func testSpread0ConcentratesBrightnessIntoABeam() {
        let box = makeBox(pattern: .cascade, spread: 0)
        let frames = CompositionEngine.render(time: 0.7, channelIDs: channels, params: box)
        let bris = frames.map(\.brightness)
        XCTAssertGreaterThan(bris.max()! - bris.min()!, 0.3,
                             "spread=0 must dim lights outside the traveling band")
    }

    // ──────────────────────────────────────────────
    // MARK: - randomize (previously dead)
    // ──────────────────────────────────────────────

    func testRandomizeGivesLightsDistinctStableColors() {
        let box = makeBox(pattern: .static, randomize: true)
        let a = CompositionEngine.render(time: 1.00, channelIDs: channels, params: box)
        let b = CompositionEngine.render(time: 1.05, channelIDs: channels, params: box)
        // Distinct colors across lights…
        XCTAssertFalse(
            abs(a[0].x - a[1].x) < 0.005 && abs(a[0].y - a[1].y) < 0.005 &&
            abs(a[1].x - a[2].x) < 0.005 && abs(a[1].y - a[2].y) < 0.005,
            "randomize must give lights different palette positions")
        // …but stable within a cycle cell (only slow drift).
        for i in 0..<3 {
            XCTAssertEqual(a[i].x, b[i].x, accuracy: 0.05)
            XCTAssertEqual(a[i].y, b[i].y, accuracy: 0.05)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - smoothing (previously dead)
    // ──────────────────────────────────────────────

    func testSmoothingLagsTheReactionDrive() {
        var loud = AudioFeatures.silent
        loud.level = 1.0
        loud.timestamp = 1

        let laggy = makeBox(reaction: ReactionConfig(source: .micAmplitude, smoothing: 100))
        _ = CompositionEngine.render(time: 0.04, channelIDs: channels, params: laggy, features: loud)
        XCTAssertLessThan(laggy.smoothedReactionLevel, 0.3,
                          "smoothing=100 (τ=0.5 s) must lag a sudden loud signal")

        let instant = makeBox(reaction: ReactionConfig(source: .micAmplitude, smoothing: 0))
        _ = CompositionEngine.render(time: 0.04, channelIDs: channels, params: instant, features: loud)
        XCTAssertGreaterThan(instant.smoothedReactionLevel, 0.9,
                             "smoothing=0 must track the drive instantly")
    }

    // ──────────────────────────────────────────────
    // MARK: - .beat source: punch brightness + quantized color advance
    // ──────────────────────────────────────────────

    func testBeatPunchIsBrightOnTheBeatAndDecaysAfter() {
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        let box = makeBox(reaction: ReactionConfig(
            source: .beat, targets: [.brightness], smoothing: 0, intensity: 70
        ))
        let onBeat = CompositionEngine.render(
            time: 0.04, channelIDs: channels, params: box,
            beat: beat, hostNow: 1000.001
        )
        let midBeat = CompositionEngine.render(
            time: 0.08, channelIDs: channels, params: box,
            beat: beat, hostNow: 1000.25
        )
        XCTAssertGreaterThan(onBeat[0].brightness, midBeat[0].brightness + 0.15,
                             "brightness must punch on the beat and decay between beats")
    }

    func testColorTargetAdvancesPalettePhasePerQuantizedBeat() {
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        let box = makeBox(reaction: ReactionConfig(
            source: .beat, targets: [.color], smoothing: 0,
            quantizeBeats: 1, colorStepPerTrigger: 0.25
        ))
        // First render anchors the trigger index — no advance.
        _ = CompositionEngine.render(time: 0.04, channelIDs: channels, params: box,
                                     beat: beat, hostNow: 1000.1)
        XCTAssertEqual(box.reactionColorPhase, 0, accuracy: 0.0001)
        // Still within beat 0 — no advance.
        _ = CompositionEngine.render(time: 0.08, channelIDs: channels, params: box,
                                     beat: beat, hostNow: 1000.4)
        XCTAssertEqual(box.reactionColorPhase, 0, accuracy: 0.0001)
        // Crossing into beat 1 — one step.
        _ = CompositionEngine.render(time: 0.12, channelIDs: channels, params: box,
                                     beat: beat, hostNow: 1000.6)
        XCTAssertEqual(box.reactionColorPhase, 0.25, accuracy: 0.0001)
        // Two beats later — two more steps (wraps mod 1).
        _ = CompositionEngine.render(time: 0.16, channelIDs: channels, params: box,
                                     beat: beat, hostNow: 1001.6)
        XCTAssertEqual(box.reactionColorPhase, 0.75, accuracy: 0.0001)
    }

    // ──────────────────────────────────────────────
    // MARK: - Beat-locked motion period
    // ──────────────────────────────────────────────

    func testMotionBeatsPerCycleLocksTheCycleToTheClock() {
        // 4 beats per cycle at 120 BPM = 2.0 s period: sample() must repeat
        // exactly one period later regardless of the speed slider.
        let motion = MotionConfig(pattern: .cascade, speed: 77, spread: 100)
        let a = motion.sample(position: 0.3, radial: nil, angular: nil,
                              lightIndex: 0, time: 5.0, overridePeriod: 2.0)
        let b = motion.sample(position: 0.3, radial: nil, angular: nil,
                              lightIndex: 0, time: 7.0, overridePeriod: 2.0)
        XCTAssertEqual(a.phase, b.phase, accuracy: 0.0001,
                       "one motion cycle must span exactly the beat-locked period")
    }

    func testRenderAppliesBeatLockedPeriod() {
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        let box = makeBox(pattern: .cascade, reaction: ReactionConfig(
            source: .beat, targets: [], motionBeatsPerCycle: 4
        ))
        // Drive sequential frames so warped time tracks elapsed time, then
        // compare colors exactly one locked period (2.0 s) apart.
        var first: LightFrame?
        var later: LightFrame?
        var t = 0.0
        while t <= 2.08 {
            let frames = CompositionEngine.render(
                time: t, channelIDs: channels, params: box,
                beat: beat, hostNow: 1000 + t
            )
            if abs(t - 0.04) < 0.001 { first = frames[1] }
            if abs(t - 2.04) < 0.001 { later = frames[1] }
            t += 0.04
        }
        XCTAssertEqual(first!.x, later!.x, accuracy: 0.01,
                       "colors must repeat after exactly one beat-locked cycle")
        XCTAssertEqual(first!.y, later!.y, accuracy: 0.01)
    }

    // ──────────────────────────────────────────────
    // MARK: - New motion patterns emit sane output
    // ──────────────────────────────────────────────

    func testAllPatternsProduceFramesInRange() {
        for pattern in MotionConfig.Pattern.allCases {
            let box = makeBox(pattern: pattern, spread: 40)
            box.radialPositions = [0.2, 0.6, 1.0]
            box.angularPositions = [0.1, 0.5, 0.9]
            for step in 0..<20 {
                let frames = CompositionEngine.render(
                    time: Double(step) * 0.04, channelIDs: channels, params: box
                )
                XCTAssertEqual(frames.count, 3)
                for f in frames {
                    XCTAssertTrue((0.0...1.0).contains(f.brightness),
                                  "\(pattern) brightness out of range: \(f.brightness)")
                    XCTAssertTrue(f.x.isFinite && f.y.isFinite && (0.0...0.9).contains(f.y),
                                  "\(pattern) emitted non-finite/out-of-gamut xy")
                }
            }
        }
    }

    func testCometHeadIsBrighterThanTail() {
        let box = makeBox(pattern: .comet, spread: 30)
        // Find a frame where brightness varies and confirm ordering exists.
        var sawContrast = false
        for step in 0..<50 {
            let frames = CompositionEngine.render(
                time: Double(step) * 0.04, channelIDs: channels, params: box
            )
            let bris = frames.map(\.brightness)
            if bris.max()! - bris.min()! > 0.4 { sawContrast = true; break }
        }
        XCTAssertTrue(sawContrast, "comet must show a bright head and dim tail")
    }

    func testTwinkleSparklesVaryAcrossLightsAndTime() {
        let box = makeBox(pattern: .twinkle, spread: 30)
        var distinctBrightness = false
        for step in 0..<80 {
            let frames = CompositionEngine.render(
                time: Double(step) * 0.05, channelIDs: channels, params: box
            )
            let bris = frames.map(\.brightness)
            if bris.max()! - bris.min()! > 0.2 { distinctBrightness = true; break }
        }
        XCTAssertTrue(distinctBrightness, "twinkle must sparkle individual lights")
    }

    // ──────────────────────────────────────────────
    // MARK: - Radial/angular geometry
    // ──────────────────────────────────────────────

    func testComputeRadialAngularNormalizesDistances() {
        // Symmetric fixture: centroid sits exactly at the origin.
        let positions: [String: (x: Double, z: Double)] = [
            "center": (0, 0), "right": (1, 0), "top": (0, 1),
            "left": (-1, 0), "bottom": (0, -1)
        ]
        let ordered = ["center", "right", "top", "left", "bottom"]
        let g = CompositionEngine.computeRadialAngular(
            lightPositions: positions, orderedLightIDs: ordered
        )
        XCTAssertEqual(g.radial.count, 5)
        XCTAssertLessThan(g.radial[0], 0.3, "the centroid-near light must have a small radius")
        XCTAssertEqual(g.radial.max()!, 1.0, accuracy: 0.001, "the farthest light must normalize to 1")
        // Opposite lights must differ in angle by ~0.5 (half a turn).
        let diff = abs(g.angular[1] - g.angular[3])
        XCTAssertEqual(min(diff, 1 - diff), 0.5, accuracy: 0.05)
    }

    // ──────────────────────────────────────────────
    // MARK: - Observation contract (@Observable box)
    // ──────────────────────────────────────────────
    // The editor panel depends on layer-config mutations being observable;
    // the \.isTabActive perf contract depends on render()'s 25fps runtime
    // writes staying @ObservationIgnored. Both directions are locked in here.

    func testLayerConfigMutationFiresObservation() {
        let box = makeBox()
        var fired = false
        withObservationTracking {
            _ = box.motion.pattern
            _ = box.reaction.source
            _ = box.envelope.shape
            _ = box.palette.mode
        } onChange: {
            fired = true
        }
        box.motion.pattern = .chase
        XCTAssertTrue(fired, "editing a layer config must invalidate the composer panel")
    }

    func testRenderFiresNoObservationOnTrackedBox() {
        var loud = AudioFeatures.silent
        loud.level = 1.0
        loud.timestamp = 1

        let box = makeBox(reaction: ReactionConfig(source: .micAmplitude, smoothing: 0))
        var fired = false
        withObservationTracking {
            _ = box.motion.pattern
            _ = box.reaction.source
            _ = box.envelope.shape
            _ = box.palette.mode
        } onChange: {
            fired = true
        }
        for step in 1...10 {
            _ = CompositionEngine.render(
                time: Double(step) * 0.04, channelIDs: channels, params: box, features: loud
            )
        }
        XCTAssertFalse(fired,
                       "render()'s per-frame runtime writes must stay @ObservationIgnored — " +
                       "observing them would re-render the Studio tab at 25fps")
    }
}
