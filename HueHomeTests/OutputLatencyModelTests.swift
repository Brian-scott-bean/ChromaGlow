// OutputLatencyModelTests.swift
// HueHome Pro — Unit Tests (Play Along P2)
//
// Render-ahead: frames are rendered for the moment the room SHOWS them.
// The lead per transport, the user's per-bridge Light timing, and Composer 2
// actually rendering musical time at hostNow + lead while the screen keeps
// showing the frame that is due now.

import XCTest
@testable import HueHome

@MainActor
final class OutputLatencyModelTests: XCTestCase {

    private let suite = "OutputLatencyModelTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        OutputLatencyModel.resetCache()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        OutputLatencyModel.resetCache()
        super.tearDown()
    }

    func testEntertainmentLeadIsLatencyPlusHalfABridgePeriod() {
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: nil), 0.1, accuracy: 1e-12)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .rest, bridgeID: nil), 0.25, accuracy: 1e-12)
    }

    func testTheUsersOffsetIsPerBridgeClampedAndPersisted() {
        OutputLatencyModel.setUserOffset(0.04, bridgeID: "a", defaults: defaults)
        OutputLatencyModel.setUserOffset(9, bridgeID: "b", defaults: defaults)
        XCTAssertEqual(OutputLatencyModel.userOffset(bridgeID: "a", defaults: defaults), 0.04, accuracy: 1e-12)
        XCTAssertEqual(OutputLatencyModel.userOffset(bridgeID: "b", defaults: defaults),
                       OutputLatencyModel.userOffsetRange.upperBound)
        XCTAssertEqual(OutputLatencyModel.userOffset(bridgeID: "c", defaults: defaults), 0)
        XCTAssertEqual(defaults.double(forKey: OutputLatencyModel.defaultsKey(bridgeID: "a")), 40, accuracy: 1e-9)
        OutputLatencyModel.resetCache()
        XCTAssertEqual(OutputLatencyModel.userOffset(bridgeID: "a", defaults: defaults), 0.04, accuracy: 1e-12,
                       "read back from defaults after the cache is gone")
    }

    func testTheLeadNeverGoesNegative() {
        OutputLatencyModel.setUserOffset(0.15, bridgeID: "late", defaults: defaults)
        _ = OutputLatencyModel.userOffset(bridgeID: "late", defaults: defaults)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "late"), 0)
    }

    /// The slider labels a negative offset "earlier". Build 908 ADDED the
    /// offset to the lead, so "earlier" rendered closer to now and the
    /// lights landed later.
    func testEarlierRendersFurtherAheadAndLaterLess() {
        OutputLatencyModel.setUserOffset(-0.06, bridgeID: "early", defaults: defaults)
        OutputLatencyModel.setUserOffset(0.03, bridgeID: "later", defaults: defaults)
        let base = OutputLatencyModel.lead(transport: .entertainment, bridgeID: nil)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "early"), base + 0.06, accuracy: 1e-12)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "later"), base - 0.03, accuracy: 1e-12)
        XCTAssertLessThan(OutputLatencyModel.userOffsetRange.lowerBound, -OutputLatencyModel.userOffsetRange.upperBound,
                          "more room on the early side: the 100 ms starting lead is a guess")
    }

    // MARK: - Composer 2 renders ahead

    /// A beat-locked pulse: rendering "now" with a 100 ms lead must equal
    /// rendering "now + 100 ms" with none — the lead moves musical time, nothing else.
    func testComposerRendersMusicalTimeAtHostNowPlusTheLead() {
        var layer = Composer2Layer.blank(name: "Pulse")
        layer.rhythm = Composer2Rhythm(shape: .pulse, periodSeconds: 1, duty: 0.3, quantizeBeats: 1)
        let look = Composer2Composition(name: "Lead", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4, phaseConfidence: 1, barConfidence: 1)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(), envelope: EnvelopeConfig(),
                                      reaction: ReactionConfig())

        let ahead = Composer2LiveOutput(composition: look)
        box.outputLead = 0.1
        let led = ahead.renderFrames(time: 5, channelIDs: [0, 1, 2], params: box, features: .silent,
                                     beat: beat, hostNow: 1010.95)

        let plain = Composer2LiveOutput(composition: look)
        box.outputLead = 0
        let later = plain.renderFrames(time: 5.1, channelIDs: [0, 1, 2], params: box, features: .silent,
                                       beat: beat, hostNow: 1011.05)
        XCTAssertEqual(led.map(\.brightness), later.map(\.brightness))
        XCTAssertEqual(later.first!.brightness, 1, accuracy: 1e-9, "just after the beat at 1011.0 the pulse is up")
    }

    func testTheScreenShowsTheFrameThatIsDueNotTheLeadingOne() {
        var layer = Composer2Layer.blank(name: "Pulse")
        layer.rhythm = Composer2Rhythm(shape: .pulse, periodSeconds: 1, duty: 0.3, quantizeBeats: 1)
        let look = Composer2Composition(name: "Lead", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(), envelope: EnvelopeConfig(),
                                      reaction: ReactionConfig())
        box.outputLead = 0.1
        let output = Composer2LiveOutput(composition: look)
        var rendered: [Double: [Double]] = [:]
        for k in 0..<10 {
            let now = 1010.5 + Double(k) * 0.04
            let frames = output.renderFrames(time: Double(k) * 0.04, channelIDs: [0], params: box,
                                             features: .silent, beat: beat, hostNow: now)
            rendered[now + 0.1] = frames.map(\.brightness)
        }
        // At 1010.82 the newest frame due was rendered for 1010.80.
        let due = output.liveFrames(at: 1010.82).map(\.brightness)
        let expected = rendered.filter { $0.key <= 1010.82 }.max { $0.key < $1.key }!.value
        XCTAssertEqual(due, expected)
        XCTAssertEqual(Composer2PreviewFeed(output: output).displayFrames(hostNow: 1010.82).count, 1)
    }
}
