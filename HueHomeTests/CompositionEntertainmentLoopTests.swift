// CompositionEntertainmentLoopTests.swift
// Chunk 2, steadier output: the composition Entertainment loop runs off the
// main actor at 50 fps. A Composer 2 look renders on the loop's own executor
// (its output is lock-guarded), so a busy screen no longer delays frames;
// legacy compositions and the Perform mixer still render on the main actor.

import QuartzCore
import XCTest
@testable import HueHome

// MARK: - The live output under concurrent use

final class Composer2LiveOutputConcurrencyTests: XCTestCase {

    private let swatches = ArtworkSwatches(
        dominant: .init(xy: Composer2XY(x: 0.17, y: 0.07), chroma: 0.3, share: 0.6),
        accent: .init(xy: Composer2XY(x: 0.6, y: 0.35), chroma: 0.25, share: 0.1),
        support: [.init(xy: Composer2XY(x: 0.2, y: 0.6), chroma: 0.2, share: 0.3)],
        isGreyscale: false)

    /// The loop renders while the screen edits the look, swaps song colours,
    /// toggles Play Along and reads the live frames — every frame still comes
    /// back whole. (Run under the Thread Sanitizer to see the races this
    /// lock removed; without it, this is the crash test.)
    func testTheLoopRendersWhileTheScreenEditsAndReads() async {
        let looks = Array(Composer2PresetLibrary.all.prefix(3))
        let output = Composer2LiveOutput(composition: looks[0])
        let channels = Array(0..<6)
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1, beatsPerBar: 4, phaseConfidence: 1, barConfidence: 1)

        let renderer = Task.detached { () -> (frames: Int, bad: Int) in
            var good = 0, bad = 0
            for k in 0..<1500 {
                let t = Double(k) * 0.02
                let frames = output.renderLiveFrames(
                    time: t, channelIDs: channels, layout: CompositionLiveLayout(outputLead: 0.1),
                    features: .silent, beat: beat, hostNow: 10 + t)
                let whole = frames.count == channels.count
                    && frames.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.brightness.isFinite }
                if whole { good += 1 } else { bad += 1 }
            }
            return (good, bad)
        }

        for k in 0..<1500 {
            output.composition = looks[k % looks.count]
            output.songSwatches = k % 2 == 0 ? swatches : nil
            output.playAlongRequested = k % 3 == 0
            output.playAlongFeel = k % 2 == 0 ? .groove : .hit
            output.eventCap = k % 2 == 0 ? 1 : 0.3
            _ = output.liveFrames(at: 10 + Double(k) * 0.02)
            _ = output.lastLiveRenderAt
            _ = output.playAlongWeight
            if k % 50 == 0 { await Task.yield() }
        }
        let result = await renderer.value
        XCTAssertEqual(result.frames, 1500)
        XCTAssertEqual(result.bad, 0)
    }

    /// A landing switch renders off the main actor too, and the playback
    /// center can read where it lands while it does.
    func testALandingRendersAndReportsConcurrently() async {
        let looks = Composer2PresetLibrary.all
        let landing = Composer2LandingSource(outgoing: Composer2LiveOutput(composition: looks[0]),
                                             incoming: Composer2LiveOutput(composition: looks[1]))
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1, beatsPerBar: 4, phaseConfidence: 1, barConfidence: 1)
        let renderer = Task.detached { () -> Int in
            var whole = 0
            for k in 0..<600 {
                let t = Double(k) * 0.02
                let frames = landing.renderLiveFrames(time: t, channelIDs: [0, 1, 2], layout: CompositionLiveLayout(),
                                                      features: .silent, beat: beat, hostNow: 10 + t)
                if frames.count == 3 { whole += 1 }
            }
            return whole
        }
        for k in 0..<600 {
            _ = landing.remaining(at: 10 + Double(k) * 0.02)
            _ = landing.hasLanded
            if k % 50 == 0 { await Task.yield() }
        }
        let whole = await renderer.value
        XCTAssertEqual(whole, 600)
        XCTAssertTrue(landing.hasLanded, "12 s of a 120 BPM bar grid always reaches the next bar line")
    }
}

// MARK: - The loop

/// Records every render: when, and on which thread.
private final class RenderRecorder: @unchecked Sendable {
    struct Render { let at: Double; let onMain: Bool; let lead: Double }
    private let lock = NSLock()
    private var _renders: [Render] = []
    var renders: [Render] { lock.lock(); defer { lock.unlock() }; return _renders }
    func note(lead: Double) {
        let render = Render(at: CACurrentMediaTime(), onMain: Thread.isMainThread, lead: lead)
        lock.lock(); _renders.append(render); lock.unlock()
    }
}

/// A Composer-2-like source: lock-guarded, so the loop may render it anywhere.
private final class ConcurrentTestSource: ConcurrentCompositionFrameSource, @unchecked Sendable {
    let recorder = RenderRecorder()
    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        renderLiveFrames(time: time, channelIDs: channelIDs, layout: CompositionLiveLayout(params: params),
                         features: features, beat: beat, hostNow: hostNow)
    }
    func renderLiveFrames(time: Double, channelIDs: [Int], layout: CompositionLiveLayout,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        recorder.note(lead: layout.outputLead)
        return channelIDs.map { LightFrame(channelID: $0, x: 0.3, y: 0.3, brightness: 0.4) }
    }
}

/// A source with no locks of its own: main-actor confined by convention.
private final class MainConfinedTestSource: CompositionFrameSource {
    let recorder = RenderRecorder()
    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        recorder.note(lead: params.outputLead)
        return channelIDs.map { LightFrame(channelID: $0, x: 0.3, y: 0.3, brightness: 0.4) }
    }
}

/// Serves the entertainment join a real area selection needs.
private final class LoopSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    var stubConfigsJSON: String = #"{"data": []}"#
    var stubEntertainmentJSON: String = #"{"data": []}"#
    var stubLights: [HueLight] = []

    override func get(path: String, ip: String, token: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if path.contains("entertainment_configuration") { return Data(stubConfigsJSON.utf8) }
        if path.contains("resource/entertainment") { return Data(stubEntertainmentJSON.utf8) }
        return Data("{}".utf8)
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        Data("{}".utf8)
    }

    override func fetchLights() async throws -> [HueLight] {
        lock.lock(); defer { lock.unlock() }
        return stubLights
    }

    override func setGroupedLightEffect(id: String, on: Bool?, brightness: Double?, xy: (Double, Double)?,
                                        mirek: Int?, duration: Int) async throws {}

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {}
}

@MainActor
final class CompositionEntertainmentLoopTests: XCTestCase {

    private var bridge: LoopSpyClient!
    private var orchestrator: UnifiedOrchestrator!
    private let bridgeID = "bridge-loop"

    override func setUp() async throws {
        try await super.setUp()
        bridge = LoopSpyClient(bridgeID: bridgeID, bridgeName: "Bridge", ip: "192.0.2.9", token: "t")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: [bridgeID: bridge])
        // Non-hex on purpose: the DTLS decode refuses before any socket
        // exists, and the stub transport replaces the socket anyway.
        try KeychainManager.shared.saveCredentials(ip: "192.0.2.9", token: "t", clientKey: "ZZ-not-hex", for: bridgeID)
        bridge.stubLights = ["L1", "L2"].enumerated().map { i, id in
            HueLight(id: id, metadata: LightMetadata(name: id, archetype: nil), on: OnState(on: true),
                     dimming: DimmingState(brightness: 100), color: nil, color_temperature: nil,
                     owner: ResourceRef(rid: "D\(i + 1)", rtype: "device"))
        }
        bridge.stubEntertainmentJSON =
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E2","owner":{"rid":"D2","rtype":"device"}}]}"#
        let channels =
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}"#
        bridge.stubConfigsJSON =
            #"{"data":[{"id":"area-a","metadata":{"name":"Bedroom"},"channels":[\#(channels)]}]}"#
        orchestrator.injectForTesting(entertainmentClientConfigurator: { client in
            await client.testEnableStubTransport()
        })
    }

    override func tearDown() async throws {
        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: bridgeID)
        await orchestrator.stopStudioMode()
        KeychainManager.shared.deleteCredentials(for: bridgeID)
        orchestrator = nil
        bridge = nil
        try await super.tearDown()
    }

    private var room: RoomDisplayItem {
        RoomDisplayItem(kind: .room, id: "room-a", name: "room-a", archetype: nil, isOn: true, brightness: 100,
                        groupedLightID: "grouped-room-a", lightCount: 2, bridgeID: bridgeID,
                        childResourceRefs: [(rid: "L1", rtype: "light"), (rid: "L2", rtype: "light")])
    }

    private func box(_ source: (any CompositionFrameSource)?) -> CompositionParamBox {
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = source
        return box
    }

    /// Waits for the loop's first frame. The loop's owning task starts on the
    /// main actor, and in the simulator the test host's launch can hold the
    /// main actor for seconds (XCTest symbolicating an AVAudioSession "hang
    /// risk" there) — which would measure the host, not the loop.
    private func firstRender(_ recorder: RenderRecorder) async throws -> Double {
        let deadline = Date().addingTimeInterval(20)
        while recorder.renders.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(recorder.renders.first, "the loop never rendered").at
    }

    private func startStreaming(_ box: CompositionParamBox) async throws {
        await orchestrator.warmEntertainmentCaches(for: room)
        let outcome = await orchestrator.startCompositionMode(room: room, paramBox: box, preferEntertainment: true)
        XCTAssertEqual(outcome, .started(transport: .entertainment),
                       "the loop under test only exists on the Entertainment transport")
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    func testAComposer2LookRendersOffTheMainActorAt50fps() async throws {
        let source = ConcurrentTestSource()
        try await startStreaming(box(source))
        let first = try await firstRender(source.recorder)
        try await Task.sleep(for: .milliseconds(1_000))

        let renders = source.recorder.renders.filter { $0.at <= first + 1.0 }
        XCTAssertGreaterThan(renders.count, 35, "~50 frames a second (\(renders.count) in 1 s)")
        XCTAssertTrue(renders.allSatisfy { !$0.onMain }, "every Composer 2 frame renders off the main actor")
        let gaps = zip(renders.dropFirst(), renders).map { $0.at - $1.at }
        XCTAssertEqual(median(gaps), 0.020, accuracy: 0.006, "on the 20 ms Entertainment grid")
        XCTAssertTrue(renders.allSatisfy { $0.lead > 0 }, "rendered the bridge's lead ahead")
    }

    func testFramesKeepFlowingWhileTheMainActorIsBusy() async throws {
        let source = ConcurrentTestSource()
        try await startStreaming(box(source))
        _ = try await firstRender(source.recorder)
        try await Task.sleep(for: .milliseconds(100))

        // The screen hangs for 400 ms (a heavy layout, a sheet, a scroll).
        let blockStart = CACurrentMediaTime()
        Thread.sleep(forTimeInterval: 0.4)
        let blockEnd = CACurrentMediaTime()

        let during = source.recorder.renders.filter { $0.at > blockStart + 0.04 && $0.at < blockEnd }
        XCTAssertGreaterThan(during.count, 10,
                             "the room kept getting frames while the main actor was blocked (\(during.count))")
    }

    func testLegacySourcesAndThePerformDeckStillRenderOnTheMainActor() async throws {
        let legacy = MainConfinedTestSource()
        try await startStreaming(box(legacy))
        _ = try await firstRender(legacy.recorder)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(legacy.recorder.renders.count, 5)
        XCTAssertTrue(legacy.recorder.renders.allSatisfy(\.onMain),
                      "a source without its own locks never leaves the main actor")
        XCTAssertTrue(legacy.recorder.renders.allSatisfy { $0.lead > 0 }, "and still gets the lead via the box")
        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: bridgeID)

        // A Composer 2 box the Perform mixer plays as deck A renders through
        // the mixer, on the main actor.
        let concurrent = ConcurrentTestSource()
        let deck = box(concurrent)
        orchestrator.activePerformanceMix = PerformanceMixBox(deckA: deck)
        try await startStreaming(deck)
        _ = try await firstRender(concurrent.recorder)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(concurrent.recorder.renders.count, 5)
        XCTAssertTrue(concurrent.recorder.renders.allSatisfy(\.onMain), "deck A renders through the mixer")

        orchestrator.activePerformanceMix = nil
        let before = concurrent.recorder.renders.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(concurrent.recorder.renders.dropFirst(before + 1).allSatisfy { !$0.onMain },
                      "and leaves the main actor once the mixer lets go")
    }
}
