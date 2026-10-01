// AudioAnalysisSourceTests.swift
// The audio-source boundary under AudioAnalysisEngine: demand lifecycle,
// generation-gated delivery, mic-path parity, presentation-time release,
// lifecycle recovery, and the interleaved → mono hopper. Runs in EVERY
// configuration — in a normal build it also proves the experiment is absent.

import AVFoundation
import QuartzCore
import XCTest
@testable import HueHome

/// Records lifecycle calls into a shared log and captures the sink it was
/// handed so tests can drive synthetic PCM through the real ingest path.
@MainActor
final class RecordingAudioSource: AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind
    let id: Int
    private let log: (String) -> Void
    var allowPrepare = true
    var allowStart = true
    private(set) var sink: AudioPCMSink?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastStopDeactivated: Bool?
    var onSystemStop: (@MainActor () async -> Void)?
    /// Simulates the system stopping the source behind the engine's back.
    var systemStopped = false
    var isLive: Bool { sink != nil && !systemStopped }

    init(kind: AudioAnalysisSourceKind, id: Int, log: @escaping (String) -> Void) {
        self.kind = kind
        self.id = id
        self.log = log
    }

    func prepare(stillWanted: @MainActor () -> Bool) async -> Bool {
        log("prepare:\(kind.rawValue)#\(id)")
        return allowPrepare
    }

    func start(sink: AudioPCMSink) -> Bool {
        guard allowStart else { return false }
        self.sink = sink
        startCount += 1
        log("start:\(kind.rawValue)#\(id)")
        return true
    }

    func stop(deactivatingSession: Bool) {
        stopCount += 1
        lastStopDeactivated = deactivatingSession
        log("stop:\(kind.rawValue)#\(id)")
    }
}

/// Synthetic mono signal: a bass tone + a mid tone, loud enough to clear the
/// extractor's noise floor.
func syntheticMono(frames: Int = 1024, sampleRate: Double = 44_100, phase: Double = 0) -> [Float] {
    (0..<frames).map { i in
        let t = (Double(i) + phase) / sampleRate
        return Float(0.6 * sin(2 * .pi * 80 * t) + 0.3 * sin(2 * .pi * 1_000 * t))
    }
}

@MainActor
final class AudioAnalysisSourceTests: XCTestCase {

    private var events: [String] = []
    private var sources: [RecordingAudioSource] = []
    private var center = NotificationCenter()
    private var inBackground = false

    private func makeEngine() -> AudioAnalysisEngine {
        AudioAnalysisEngine(makeSource: { [unowned self] kind in
            let source = RecordingAudioSource(kind: kind, id: self.sources.count) { [unowned self] in
                self.events.append($0)
            }
            self.sources.append(source)
            return source
        }, notificationCenter: center, isInBackground: { [unowned self] in self.inBackground })
    }

    override func setUp() async throws {
        events = []
        sources = []
        center = NotificationCenter()
        inBackground = false
    }

    private func deliverLoudHop(_ sink: AudioPCMSink, presentationTime: Double = CACurrentMediaTime()) {
        let mono = syntheticMono()
        mono.withUnsafeBufferPointer { buf in
            sink.deliver(mono: buf.baseAddress!, frameCount: buf.count, sampleRate: 44_100,
                         presentationTime: presentationTime, buffer: nil)
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Defaults / distribution

    func testMicrophoneIsTheDefaultSource() {
        XCTAssertEqual(AudioAnalysisEngine.shared.sourceKind, .microphone)
        XCTAssertTrue(AudioAnalysisEngine.defaultSource(.microphone) is MicrophoneAudioSource)
    }

    func testNormalBuildsContainOnlyTheMicrophoneSource() {
        #if CHROMAGLOW_EXPERIMENTAL_SPOTIFY
        XCTAssertEqual(Set(AudioAnalysisSourceKind.allCases.map(\.rawValue)), ["microphone", "spotifyConnect"])
        #else
        // The experiment compiles out: no Spotify source kind exists.
        XCTAssertEqual(AudioAnalysisSourceKind.allCases, [.microphone])
        #endif
    }

    // MARK: - Demand lifecycle

    func testDemandStartsOneSourceAndLastReleaseStopsIt() async {
        let engine = makeEngine()
        let started = await engine.setDemand(.composerReaction, active: true)
        XCTAssertTrue(started)
        XCTAssertTrue(engine.isRunning)
        let second = await engine.setDemand(.performance, active: true)
        XCTAssertTrue(second)
        XCTAssertEqual(sources.count, 1, "a second demand reuses the running source")

        await engine.setDemand(.composerReaction, active: false)
        XCTAssertTrue(engine.isRunning, "still held by .performance")
        await engine.setDemand(.performance, active: false)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(events, ["prepare:microphone#0", "start:microphone#0", "stop:microphone#0"])
    }

    func testFailedPreflightOrStartLeavesNothingRunning() async {
        let engine = AudioAnalysisEngine(makeSource: { kind in
            let s = RecordingAudioSource(kind: kind, id: 0) { _ in }
            s.allowPrepare = false
            return s
        }, notificationCenter: center)
        let ok = await engine.setDemand(.composerReaction, active: true)
        XCTAssertFalse(ok)
        XCTAssertFalse(engine.isRunning)
        await engine.setDemand(.composerReaction, active: false)

        var refused: RecordingAudioSource?
        let engine2 = AudioAnalysisEngine(makeSource: { kind in
            let s = RecordingAudioSource(kind: kind, id: 0) { _ in }
            s.allowStart = false
            refused = s
            return s
        }, notificationCenter: center)
        let ok2 = await engine2.setDemand(.composerReaction, active: true)
        XCTAssertFalse(ok2)
        XCTAssertFalse(engine2.isRunning)
        XCTAssertNil(refused?.sink)
        await engine2.setDemand(.composerReaction, active: false)
    }

    // MARK: - Delivery + invalidation

    func testFeaturesFlowThroughTheSinkAndStopInvalidatesLateDeliveries() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let sink = try XCTUnwrap(sources.first?.sink)
        XCTAssertTrue(sink.isCurrent)

        deliverLoudHop(sink)
        let live = AudioAnalysisEngine.latestFeatures()
        XCTAssertGreaterThan(live.rawOverall, 0.05, "synthetic PCM reached the shared extractor")
        XCTAssertGreaterThan(live.rawBass, 0)

        await engine.setDemand(.composerReaction, active: false)
        XCTAssertFalse(sink.isCurrent)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "stop publishes silence")

        // A callback still in flight from the stopped source lands now.
        deliverLoudHop(sink)
        sink.publishSilence()
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures(), AudioFeatures.silent,
                       "stale deliveries are dropped at the sink")
    }

    func testRepeatedStartStopNeverLeaksASource() async {
        let engine = makeEngine()
        for cycle in 0..<50 {
            await engine.setDemand(.composerReaction, active: true)
            XCTAssertEqual(sources.count, cycle + 1)
            await engine.setDemand(.composerReaction, active: false)
        }
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(sources.allSatisfy { $0.startCount == 1 && $0.stopCount == 1 })
        XCTAssertTrue(sources.allSatisfy { $0.sink?.isCurrent == false })
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures(), AudioFeatures.silent)
    }

    /// The mic tap's path (deliver(buffer:)) must produce exactly what the
    /// pre-boundary inline tap produced: AudioFeatureExtractor.process on
    /// channel 0. Compared against a fresh extractor fed the same samples.
    func testMicBufferPathMatchesTheExtractorExactly() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let sink = try XCTUnwrap(sources.first?.sink)

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = syntheticMono(sampleRate: 48_000)
        buffer.floatChannelData![0].update(from: samples, count: 1024)

        final class TapCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let tapped = TapCounter()
        AudioAnalysisEngine.addBufferTap(id: "parity-test") { _, _ in tapped.bump() }
        defer { AudioAnalysisEngine.removeBufferTap(id: "parity-test") }

        sink.deliver(buffer: buffer, sampleRate: 48_000, when: nil)
        let published = AudioAnalysisEngine.latestFeatures()

        let reference = AudioFeatureExtractor()
        let expected = try XCTUnwrap(samples.withUnsafeBufferPointer {
            reference.process(data: $0.baseAddress!, frameCount: 1024, sampleRate: 48_000,
                              hostTime: published.timestamp)
        })
        XCTAssertEqual(published.level, expected.level)
        XCTAssertEqual(published.bass, expected.bass)
        XCTAssertEqual(published.mid, expected.mid)
        XCTAssertEqual(published.treble, expected.treble)
        XCTAssertEqual(published.rawOverall, expected.rawOverall)
        XCTAssertEqual(published.rawBass, expected.rawBass)
        XCTAssertEqual(published.rawMid, expected.rawMid)
        XCTAssertEqual(published.rawTreble, expected.rawTreble)
        XCTAssertEqual(published.onsetStrength, expected.onsetStrength)
        XCTAssertEqual(tapped.count, 1, "raw buffer still fans out to taps")
        await engine.setDemand(.composerReaction, active: false)
    }

    // MARK: - Presentation time

    func testFutureHopsAreRevealedOnlyAtTheirPresentationTime() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let sink = try XCTUnwrap(sources.first?.sink)

        deliverLoudHop(sink, presentationTime: CACurrentMediaTime() + 0.2)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "not heard yet")
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05, "heard now")

        // Pending hops die with the activation.
        deliverLoudHop(sink, presentationTime: CACurrentMediaTime() + 0.1)
        await engine.setDemand(.composerReaction, active: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures(), AudioFeatures.silent)
    }

    func testPublishSilenceKeepsTheActivationLive() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let sink = try XCTUnwrap(sources.first?.sink)
        deliverLoudHop(sink)
        sink.publishSilence()
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0)
        XCTAssertTrue(sink.isCurrent)
        deliverLoudHop(sink)
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testDelayLineIsBoundedAndOrdered() {
        var line = AnalysisFeatureDelayLine()
        for i in 0..<(AnalysisFeatureDelayLine.capacity + 100) {
            var f = AudioFeatures()
            f.timestamp = Double(i)
            f.level = Float(i)
            line.append(f)
        }
        XCTAssertEqual(line.count, AnalysisFeatureDelayLine.capacity, "overwrite-oldest, never grows")
        XCTAssertNil(line.popDue(now: 50), "the oldest 100 were dropped")
        let due = line.popDue(now: 120)
        XCTAssertEqual(due?.level, 120, "returns the newest due frame")
        XCTAssertEqual(line.count, AnalysisFeatureDelayLine.capacity + 100 - 121)
        line.removeAll()
        XCTAssertTrue(line.isEmpty)
    }

    // MARK: - Lifecycle recovery

    func testBackgroundStopsTheSourceAndForegroundRestartsIt() async {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil { !engine.isRunning }
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(sources.first?.stopCount, 1)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil { engine.isRunning }
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(sources.count, 2, "a fresh source instance per activation")
        XCTAssertEqual(sources.first?.sink?.isCurrent, false)
        XCTAssertEqual(sources.last?.sink?.isCurrent, true)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testInterruptionStopsAndResumes() async {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { !engine.isRunning }
        XCTAssertFalse(engine.isRunning)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await waitUntil { engine.isRunning }
        XCTAssertTrue(engine.isRunning)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testInterruptionEndingInTheBackgroundWaitsForTheForeground() async {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { !engine.isRunning }
        inBackground = true
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await waitUntil(0.3) { engine.isRunning }
        XCTAssertFalse(engine.isRunning, "no automatic restart while backgrounded")
        XCTAssertEqual(sources.count, 1)
        inBackground = false
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil { engine.isRunning }
        XCTAssertTrue(engine.isRunning)
        await engine.setDemand(.composerReaction, active: false)
    }

    /// A source the system stopped (hardware reconfiguration) is rebuilt on
    /// a fresh activation without bouncing the session; a stale report from
    /// the old source after the rebuild is ignored.
    func testSystemStoppedSourceIsRebuiltWithoutBouncingTheSession() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let first = try XCTUnwrap(sources.first)
        let staleReport = try XCTUnwrap(first.onSystemStop)
        first.systemStopped = true
        await staleReport()
        XCTAssertEqual(sources.count, 2, "rebuilt on a fresh source")
        XCTAssertEqual(first.lastStopDeactivated, false, "a rebuild leaves the session up")
        XCTAssertNil(first.onSystemStop, "the engine detaches the old source")
        XCTAssertEqual(first.sink?.isCurrent, false)
        XCTAssertEqual(sources.last?.sink?.isCurrent, true)
        XCTAssertTrue(engine.isRunning)

        await staleReport()
        XCTAssertEqual(sources.count, 2, "a late report from the replaced source does nothing")
        await engine.setDemand(.composerReaction, active: false)
        XCTAssertEqual(sources.last?.lastStopDeactivated, true, "a real stop releases the session")
    }

    /// A route change rebuilds a source that is running on paper but dead.
    func testRouteChangeRebuildsADeadSourceAndLeavesAHealthyOneAlone() async throws {
        let engine = makeEngine()
        await engine.setDemand(.composerReaction, active: true)
        let routeChange: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        ]
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: routeChange)
        await waitUntil(0.3) { sources.count > 1 }
        XCTAssertEqual(sources.count, 1, "a healthy source is left alone")

        sources[0].systemStopped = true
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: routeChange)
        await waitUntil { sources.count == 2 }
        XCTAssertEqual(sources.count, 2, "a dead source is rebuilt")
        XCTAssertEqual(sources[0].lastStopDeactivated, false)
        XCTAssertTrue(engine.isRunning)
        await engine.setDemand(.composerReaction, active: false)
    }

    // MARK: - Hopper

    func testHopperDownmixesAndReblocksIntoFixedHops() {
        let hopper = InterleavedPCMHopper(hopFrames: 1024)
        var hops: [[Float]] = []
        var bufferFrames: [AVAudioFrameCount] = []
        let chunk: [Float] = (0..<(700 * 2)).map { $0 % 2 == 0 ? 1 : 0 }   // L = 1, R = 0
        for _ in 0..<3 {
            chunk.withUnsafeBufferPointer { buf in
                hopper.push(buf.baseAddress!, frames: 700, channels: 2, sampleRate: 44_100) { mono, count, buffer in
                    hops.append(Array(UnsafeBufferPointer(start: mono, count: count)))
                    bufferFrames.append(buffer?.frameLength ?? 0)
                    XCTAssertEqual(buffer?.format.sampleRate, 44_100)
                    XCTAssertEqual(buffer?.format.channelCount, 1)
                }
            }
        }
        XCTAssertEqual(hops.count, 2, "2100 frames → two 1024-frame hops, 52 carried")
        XCTAssertTrue(hops.allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0.5 } }, "L=1, R=0 → 0.5")
        XCTAssertEqual(bufferFrames, [1024, 1024])

        hopper.reset()
        var afterReset = 0
        chunk.withUnsafeBufferPointer { buf in
            hopper.push(buf.baseAddress!, frames: 700, channels: 2, sampleRate: 44_100) { _, _, _ in afterReset += 1 }
        }
        XCTAssertEqual(afterReset, 0, "reset drops the partial hop")
    }
}
