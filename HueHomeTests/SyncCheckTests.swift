// SyncCheckTests.swift
// Chunk 2, item 3: Sync Check. The blink plan stays slow and safe, the
// pattern stamps when each blink was sent and keeps the look alive under
// it, the analyzer recovers a known delay from synthetic camera footage
// (including through a model of the bridge's 25 Hz radio), the measurement
// becomes the render lead, and the playback center lends its live box and
// takes it back.

import XCTest
@testable import HueHome

// MARK: - Plan and pattern

final class SyncCheckPlanTests: XCTestCase {

    func testBlinksAreSlowJitteredAndReproducible() {
        let plan = SyncCheckPlan(seed: 7, dimFlashing: false)
        XCTAssertEqual(plan.onsets.count, SyncCheckPlan.blinkCount)
        XCTAssertEqual(plan.onsets.first ?? 0, plan.settle + plan.gap, accuracy: 1e-12)
        let gaps = zip(plan.onsets.dropFirst(), plan.onsets).map { $0 - $1 }
        for gap in gaps {
            XCTAssertTrue(SyncCheckPlan.spacing.contains(gap))
            XCTAssertGreaterThan(gap, BeatMath.FlashSafety.minOnsetLedgerPeriod * 2,
                                 "far slower than the flash limit, so the gate never holds a blink")
        }
        XCTAssertGreaterThan(Set(gaps.map { ($0 * 1000).rounded() }).count, 8, "jittered, not a fixed rhythm")
        XCTAssertEqual(SyncCheckPlan(seed: 7, dimFlashing: false), plan)
        XCTAssertNotEqual(SyncCheckPlan(seed: 8, dimFlashing: false).onsets, plan.onsets)
        XCTAssertGreaterThanOrEqual(plan.duration,
                                    plan.onsets.last! + SyncCheckAnalyzer.maxDelay + plan.onDuration,
                                    "the slowest accepted delay still lands inside the check")
        XCTAssertLessThan(plan.duration, 22, "about 20 seconds, as the screen says")
    }

    func testLevelsSettleBrightThenBlinkFromDark() {
        let plan = SyncCheckPlan(seed: 1, dimFlashing: false)
        XCTAssertEqual(plan.level(at: 0.5), plan.onLevel)
        XCTAssertEqual(plan.level(at: plan.settle + 0.1), plan.offLevel)
        XCTAssertEqual(plan.level(at: plan.onsets[3] + 0.01), plan.onLevel)
        XCTAssertEqual(plan.blink(at: plan.onsets[3] + 0.01), 3)
        XCTAssertEqual(plan.level(at: plan.onsets[3] + plan.onDuration + 0.01), plan.offLevel)
        XCTAssertNil(plan.blink(at: plan.onsets[3] - 0.01))
        XCTAssertEqual(SyncCheckPlan(seed: 1, dimFlashing: true).onLevel, 0.45, "Dim Flashing Lights: a gentler step")
    }
}

/// Counts the look's frames under the pattern.
private final class LookSpy: ConcurrentCompositionFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _renders = 0
    var renders: Int { lock.lock(); defer { lock.unlock() }; return _renders }
    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        renderLiveFrames(time: time, channelIDs: channelIDs, layout: CompositionLiveLayout(),
                         features: features, beat: beat, hostNow: hostNow)
    }
    func renderLiveFrames(time: Double, channelIDs: [Int], layout: CompositionLiveLayout,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        lock.lock(); _renders += 1; lock.unlock()
        return channelIDs.map { LightFrame(channelID: $0, x: 0.2, y: 0.6, brightness: 0.77) }
    }
}

final class SyncCheckPatternTests: XCTestCase {

    private let beat = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4)

    private func render(_ pattern: SyncCheckPattern, at hostNow: Double, channels: [Int] = [0, 1, 2]) -> [LightFrame] {
        pattern.renderLiveFrames(time: 0, channelIDs: channels, layout: CompositionLiveLayout(outputLead: 0.1),
                                 features: .silent, beat: beat, hostNow: hostNow)
    }

    func testBlinksFollowTheSendClockAndStampTheirFirstFrame() {
        let plan = SyncCheckPlan(seed: 3, dimFlashing: false, blinkCount: 4)
        let pattern = SyncCheckPattern(plan: plan)
        let look = LookSpy()
        pattern.wrap(look)
        let t0 = 500.0
        var t = t0
        var frames: [(Double, [LightFrame])] = []
        while t < t0 + plan.duration + 0.5 {
            frames.append((t, render(pattern, at: t)))
            t += 0.02
        }
        XCTAssertEqual(pattern.startedAt, t0)
        XCTAssertEqual(look.renders, frames.count, "the look keeps rendering underneath, every frame")
        for (k, onset) in plan.onsets.enumerated() {
            let sent = try! XCTUnwrap(pattern.sentAt[k])
            XCTAssertGreaterThanOrEqual(sent, t0 + onset - 1e-9)
            XCTAssertLessThan(sent - (t0 + onset), 0.02 + 1e-9, "the first 20 ms frame at or after the onset")
            let frame = frames.first { abs($0.0 - sent) < 1e-9 }!.1
            XCTAssertTrue(frame.allSatisfy { $0.brightness == plan.onLevel }, "that frame is the blink, on every light")
            XCTAssertEqual(frame.map(\.channelID), [0, 1, 2])
        }
        XCTAssertEqual(pattern.blinksSent, 4)
        XCTAssertTrue(pattern.isFinished(at: t0 + plan.duration + 1e-6))
        XCTAssertFalse(pattern.isFinished(at: t0 + plan.duration - 0.01))
        // Ignores the lead: the blink is rendered for the moment it is sent.
        let dark = frames.first { $0.0 > t0 + plan.settle + 0.05 }!.1
        XCTAssertEqual(dark.first?.brightness, plan.offLevel)
        // Over: the look shows again, unchanged.
        XCTAssertEqual(frames.last?.1.first?.brightness, 0.77)
        XCTAssertEqual(frames.last?.1.first?.x, 0.2)
    }
}

// MARK: - Analyzer

/// Synthetic camera footage of a room whose light answers blinks after a
/// known delay, with noise and things in view that are not the light.
private struct Footage {
    var fps = 240.0
    var litCell = 37
    var dark: Float = 40
    var lit: Float = 160
    var noise: Float = 2
    /// Linear ramp from dark to lit.
    var rise = 0.03
    var fall = 0.05
    var onDuration = 0.35
    var distractors = true
    /// Whether blink `i` is in view.
    var visible: (Int) -> Bool = { _ in true }
    /// Frames the camera dropped.
    var dropped: (Double) -> Bool = { _ in false }

    /// `delays[i]`: send → the light starts rising, for blink i.
    func samples(sent: [Double], delays: [Double]) -> [SyncCheckSample] {
        var random = TestRandom(seed: 99)
        var out: [SyncCheckSample] = []
        let start = sent[0] - 0.5
        let end = sent[sent.count - 1] + 1.0
        var t = start
        var tvLevel: Float = 90
        var tvNext = start
        while t < end {
            defer { t += 1 / fps }
            if dropped(t) { continue }
            var level = 0.0
            for (i, s) in sent.enumerated() where visible(i) {
                let up = s + delays[i], down = s + onDuration + delays[i]
                if t >= up && t < down { level = max(level, min(1, (t - up) / rise)) }
                else if t >= down { level = max(level, max(0, 1 - (t - down) / fall) * min(1, (down - up) / rise)) }
            }
            var cells = (0..<(SyncCheckLuma.columns * SyncCheckLuma.rows)).map { _ in 30 + noise * random.gaussian() }
            cells[litCell] = dark + (lit - dark) * Float(level) + noise * random.gaussian()
            if distractors {
                cells[0] = 255                                   // a window, clipped
                if t >= tvNext { tvLevel = Float(40 + random.unit() * 160); tvNext = t + 0.1 + random.unit() * 0.4 }
                cells[1] = tvLevel + noise * random.gaussian()   // a TV
                let other = (t * 1.43).truncatingRemainder(dividingBy: 1) < 0.5
                cells[2] = (other ? 150 : 50) + noise * random.gaussian()   // a lamp on its own rhythm
            }
            out.append(SyncCheckSample(time: t, cells: cells))
        }
        return out
    }
}

private struct TestRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Roughly standard normal (sum of four uniforms).
    mutating func gaussian() -> Float {
        Float((unit() + unit() + unit() + unit() - 2) * 1.732)
    }
}

final class SyncCheckAnalyzerTests: XCTestCase {

    private let plan = SyncCheckPlan(seed: 11, dimFlashing: false)

    private var sent: [Double] { plan.onsets.map { 1000 + $0 + 0.007 } }

    /// 72 ms to the bridge plus a wait for the radio's next 40 ms update.
    private func bridgeDelays(base: Double = 0.072, seed: UInt64 = 5) -> [Double] {
        var random = TestRandom(seed: seed)
        return sent.map { _ in base + random.unit() * 0.04 }
    }

    /// The analyzer's summary: the mean of the middle half.
    private func middleMean(_ values: [Double]) -> Double {
        let s = values.sorted()
        let middle = s[(s.count / 4)..<(s.count - s.count / 4)]
        return middle.reduce(0, +) / Double(middle.count)
    }

    private func measure(_ footage: Footage, delays: [Double], sentAt: [Double?]? = nil) -> Result<SyncCheckAnalyzer.Measurement, SyncCheckAnalyzer.Failure> {
        SyncCheckAnalyzer.measure(samples: footage.samples(sent: sent, delays: delays),
                                  sentAt: sentAt ?? sent, onDuration: plan.onDuration)
    }

    func testRecoversTheDelayToHalfBrightnessAtEveryCameraRate() throws {
        let delays = bridgeDelays()
        let truth = middleMean(delays) + 0.015   // half way up a 30 ms rise
        for (fps, tolerance) in [(240.0, 0.003), (120.0, 0.004), (60.0, 0.008)] {
            var footage = Footage()
            footage.fps = fps
            let m = try measure(footage, delays: delays).get()
            XCTAssertEqual(m.latency, truth, accuracy: tolerance, "\(Int(fps)) fps")
            XCTAssertEqual(m.cell, footage.litCell, "found the light, not the window, the TV or the other lamp")
            XCTAssertEqual(m.delays.count, plan.onsets.count)
            XCTAssertLessThan(m.spread, 0.04, "the radio's 40 ms update wait is the only spread")
        }
    }

    func testASlowBridgeAndAGentleBlinkAreStillMeasured() throws {
        var footage = Footage()
        footage.lit = 62        // Dim Flashing Lights, a light off to the side
        footage.noise = 1.5
        let delays = bridgeDelays(base: 0.38)
        let m = try measure(footage, delays: delays).get()
        XCTAssertEqual(m.latency, middleMean(delays) + 0.015, accuracy: 0.004)
    }

    func testNothingBlinkingIsReportedNotGuessed() {
        var footage = Footage()
        footage.visible = { _ in false }
        XCTAssertEqual(measure(footage, delays: bridgeDelays()).failure, .lightNotSeen)
    }

    func testALightOutOfViewForMostBlinksIsTooFewNotAnAverageOfNoise() {
        var footage = Footage()
        footage.visible = { $0 < 5 }
        guard case .tooFewBlinks(let seen, let sent)? = measure(footage, delays: bridgeDelays()).failure else {
            return XCTFail("expected too few blinks")
        }
        XCTAssertEqual(seen, 5)
        XCTAssertEqual(sent, plan.onsets.count)
    }

    func testDisagreeingDelaysAreRefused() {
        let delays = sent.indices.map { $0 % 2 == 0 ? 0.08 : 0.2 }
        guard case .inconsistent(let spread)? = measure(Footage(), delays: delays).failure else {
            return XCTFail("expected inconsistent")
        }
        XCTAssertGreaterThan(spread, SyncCheckAnalyzer.maxSpread)
    }

    func testDroppedFramesAcrossARiseSkipThatBlinkOnly() throws {
        let delays = bridgeDelays()
        var footage = Footage()
        let gaps = [1, 6].map { (sent[$0] + delays[$0] - 0.03, sent[$0] + delays[$0] + 0.06) }
        footage.dropped = { t in gaps.contains { t >= $0.0 && t < $0.1 } }
        let m = try measure(footage, delays: delays).get()
        XCTAssertEqual(m.delays.count, plan.onsets.count - 2)
        XCTAssertEqual(m.latency, middleMean(delays.enumerated().filter { ![1, 6].contains($0.offset) }.map(\.element)) + 0.015,
                       accuracy: 0.003)
    }

    func testBlinksThatWereNeverSentAreLeftOut() throws {
        let delays = bridgeDelays()
        var sentAt: [Double?] = sent
        sentAt[sentAt.count - 1] = nil
        let m = try measure(Footage(), delays: delays, sentAt: sentAt).get()
        XCTAssertEqual(m.blinksSent, plan.onsets.count - 1)
    }

    /// End to end through a model of the bridge: the pattern renders on the
    /// stream's ~20 ms grid (with the pacer's jitter), each frame reaches the
    /// bridge 30–36 ms later (Wi-Fi), the bridge updates its lights every
    /// 40 ms at a phase the app cannot know, and a bulb takes 30 ms to rise.
    /// Every blink is timed to within a few ms of when the bulb really
    /// crossed half way, and the lead is what a rendered beat pays on average.
    func testThroughABridgeModelEveryBlinkIsTimedAndTheLeadIsTheirMean() throws {
        let plan = SyncCheckPlan(seed: 21, dimFlashing: false)
        let pattern = SyncCheckPattern(plan: plan)
        var random = TestRandom(seed: 4)
        let t0 = 2000.003
        var arrivals: [Double] = [], levels: [Double] = []
        var t = t0
        while t < t0 + plan.duration + 0.2 {
            let frame = pattern.renderLiveFrames(time: 0, channelIDs: [0], layout: CompositionLiveLayout(),
                                                 features: .silent, beat: BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4),
                                                 hostNow: t)
            arrivals.append(t + 0.030 + random.unit() * 0.006)
            levels.append(frame[0].brightness)
            t += 0.02 + (random.unit() - 0.5) * 0.002
        }
        let radioPeriod = 0.040, radioPhase = 0.0137, rise = 0.030
        /// The newest frame the bridge had by `time`.
        func held(_ time: Double) -> Double {
            var lo = 0, hi = arrivals.count
            while lo < hi { let mid = (lo + hi) / 2; if arrivals[mid] <= time { lo = mid + 1 } else { hi = mid } }
            return lo == 0 ? 0 : levels[lo - 1]
        }
        func shown(_ time: Double) -> Double {
            let tick = ((time - radioPhase) / radioPeriod).rounded(.down) * radioPeriod + radioPhase
            let target = held(tick), before = held(tick - radioPeriod)
            return before + (target - before) * min(1, (time - tick) / rise)
        }
        func camera(_ time: Double) -> Float { Float(20 + 200 * shown(time)) }

        var samples: [SyncCheckSample] = []
        var c = t0 + plan.settle
        while c < t0 + plan.duration {
            var cells = [Float](repeating: 30, count: SyncCheckLuma.columns * SyncCheckLuma.rows)
            cells[50] = camera(c)
            samples.append(SyncCheckSample(time: c, cells: cells))
            c += 1 / 240.0
        }
        // The truth: when each bulb really crossed half way.
        let half = Float(20 + 200 * (plan.offLevel + plan.onLevel) / 2)
        let truths = try pattern.sentAt.map { sent -> Double in
            let s = try XCTUnwrap(sent)
            var probe = s
            while camera(probe) < half { probe += 0.00005 }
            return probe - s
        }

        let m = try SyncCheckAnalyzer.measure(samples: samples, sentAt: pattern.sentAt, onDuration: plan.onDuration).get()
        XCTAssertEqual(m.cell, 50)
        XCTAssertEqual(m.delays.count, truths.count)
        for (measured, truth) in zip(m.delays, truths) {
            XCTAssertEqual(measured, truth, accuracy: 0.003)
        }
        XCTAssertEqual(m.latency, middleMean(truths), accuracy: 0.002)
        XCTAssertTrue((0.030 + rise * 0.4)...(0.036 + radioPeriod + rise * 0.6) ~= m.latency,
                      "network + a radio wait + half a rise (\(m.latency))")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

// MARK: - Camera frame reduction

final class SyncCheckLumaTests: XCTestCase {

    func testTheGridAveragesEachCellAndIgnoresRowPadding() {
        let width = 160, height = 90, bytesPerRow = 176
        var plane = [UInt8](repeating: 10, count: bytesPerRow * height)
        // The bottom-right cell is bright; the padding past each row is noise.
        for y in 0..<height {
            for x in width..<bytesPerRow { plane[y * bytesPerRow + x] = 255 }
            for x in (width - 10)..<width where y >= height - 10 { plane[y * bytesPerRow + x] = 200 }
        }
        let cells = plane.withUnsafeBufferPointer {
            SyncCheckLuma.grid($0.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow, step: 1)
        }
        XCTAssertEqual(cells.count, SyncCheckLuma.columns * SyncCheckLuma.rows)
        XCTAssertEqual(cells.last ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(cells.first ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(cells[SyncCheckLuma.columns - 1], 10, accuracy: 0.01, "row padding never leaks into a cell")
    }
}

// MARK: - The measurement becomes the lead

@MainActor
final class SyncCheckLatencyTests: XCTestCase {

    private let suite = "SyncCheckLatencyTests"
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

    func testAMeasurementReplacesTheStartingLeadAndResetsTheSlider() {
        OutputLatencyModel.setUserOffset(-0.05, bridgeID: "b", defaults: defaults)
        XCTAssertNil(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        OutputLatencyModel.setMeasuredLatency(0.137, bridgeID: "b", at: when, defaults: defaults)
        XCTAssertEqual(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults) ?? 0, 0.137, accuracy: 1e-9)
        XCTAssertEqual(OutputLatencyModel.measuredDate(bridgeID: "b", defaults: defaults), when)
        XCTAssertEqual(OutputLatencyModel.userOffset(bridgeID: "b", defaults: defaults), 0, "the measurement is the new on time")
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "b"), 0.137, accuracy: 1e-9)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .rest, bridgeID: "b"), OutputLatencyModel.restLatency,
                       accuracy: 1e-9, "Room mode is not measured")
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "other"), 0.1, accuracy: 1e-9)

        // A trim on top of the measurement still moves the lights.
        OutputLatencyModel.setUserOffset(-0.02, bridgeID: "b", defaults: defaults)
        XCTAssertEqual(OutputLatencyModel.lead(transport: .entertainment, bridgeID: "b"), 0.157, accuracy: 1e-9)

        OutputLatencyModel.resetCache()
        XCTAssertEqual(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults) ?? 0, 0.137, accuracy: 1e-9,
                       "persisted per bridge")
    }

    func testMeasurementsAreClampedAndCanBeForgotten() {
        OutputLatencyModel.setMeasuredLatency(3, bridgeID: "b", defaults: defaults)
        XCTAssertEqual(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults),
                       OutputLatencyModel.measuredRange.upperBound)
        OutputLatencyModel.setMeasuredLatency(nil, bridgeID: "b", defaults: defaults)
        XCTAssertNil(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults))
        XCTAssertNil(OutputLatencyModel.measuredDate(bridgeID: "b", defaults: defaults))
        OutputLatencyModel.resetCache()
        XCTAssertNil(OutputLatencyModel.measuredLatency(bridgeID: "b", defaults: defaults))
        defaults.set(-5.0, forKey: OutputLatencyModel.measuredKey(bridgeID: "junk"))
        XCTAssertNil(OutputLatencyModel.measuredLatency(bridgeID: "junk", defaults: defaults), "nonsense on disk is ignored")
    }
}

// MARK: - The playback center lends its live box

@MainActor
final class Composer2LabSyncCheckTests: XCTestCase {

    private func document(_ composition: Composer2Composition) -> Composer2Document {
        var context = Composer2RoomContext(room: Composer2LabFixtures.room("r1"))
        context.lights = Composer2LabFixtures.lights
        context.layout = Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights)
        return Composer2Document(composition: composition, roomContext: context)
    }

    private func liveCenter(_ gateway: Composer2FakeGateway) async -> (Composer2PlaybackCenter, Composer2LiveOutput) {
        let center = Composer2PlaybackCenter(observeApplication: false)
        center.now = { 100 }
        center.attachScreen()
        let doc = document(Composer2PresetLibrary.auroraDrift)
        let output = Composer2LiveOutput(composition: doc.composition)
        _ = await center.start(document: doc, output: output, gateway: gateway, audition: false)
        return (center, output)
    }

    private var pattern: SyncCheckPattern { SyncCheckPattern(plan: SyncCheckPlan(seed: 1, dimFlashing: false)) }

    func testTheCheckBorrowsTheStreamAndHandsTheLookBack() async {
        let gateway = Composer2FakeGateway()
        let (center, output) = await liveCenter(gateway)
        let box = gateway.boxes[0]
        XCTAssertTrue(center.canSyncCheck(bridgeID: "b1"))
        XCTAssertFalse(center.canSyncCheck(bridgeID: "another bridge"))

        let check = pattern
        XCTAssertTrue(center.beginSyncCheck(check))
        XCTAssertTrue(box.frameSource === check, "the stream plays the blinks")
        XCTAssertTrue(check.wrapped === output, "with the look underneath")
        XCTAssertFalse(center.beginSyncCheck(pattern), "one check at a time")

        center.endSyncCheck()
        XCTAssertTrue(box.frameSource === output, "the look is back, exactly")
        XCTAssertNil(check.wrapped)
        XCTAssertTrue(center.isLive)
    }

    func testRoomModeHasNothingToMeasure() async {
        let gateway = Composer2FakeGateway()
        gateway.startOutcome = .started(.roomMode)
        let (center, output) = await liveCenter(gateway)
        XCTAssertFalse(center.canSyncCheck(bridgeID: "b1"))
        XCTAssertFalse(center.beginSyncCheck(pattern))
        XCTAssertTrue(gateway.boxes[0].frameSource === output)
    }

    func testALookSwitchDuringTheCheckWins() async {
        let gateway = Composer2FakeGateway()
        let (center, _) = await liveCenter(gateway)
        let box = gateway.boxes[0]
        XCTAssertTrue(center.beginSyncCheck(pattern))

        let next = document(Composer2PresetLibrary.christmasChase)
        let nextOutput = Composer2LiveOutput(composition: next.composition)
        _ = await center.start(document: next, output: nextOutput, gateway: gateway, audition: false)
        XCTAssertTrue(box.frameSource === nextOutput)

        center.endSyncCheck()
        XCTAssertTrue(box.frameSource === nextOutput, "ending the check never puts the old look back over the new one")
    }

    func testStoppingDuringTheCheckReleasesIt() async {
        let gateway = Composer2FakeGateway()
        let (center, _) = await liveCenter(gateway)
        let box = gateway.boxes[0]
        let check = pattern
        XCTAssertTrue(center.beginSyncCheck(check))
        await center.stop(gateway: gateway)
        XCTAssertNil(box.frameSource)
        XCTAssertNil(check.wrapped)
        center.endSyncCheck()   // harmless afterwards
        XCTAssertNil(box.frameSource)
    }
}
