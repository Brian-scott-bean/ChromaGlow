// Composer2LabIntegrationTests.swift
// ChromaGlow — Composer 2 lab (experimental), v2.1.
//
// The orchestrator-side seams Composer 2.1 relies on, exercised on a real
// UnifiedOrchestrator with no bridge: the Dashboard stop route, the Now
// Playing registry adapter, and the attended start's refusal to prompt when
// nothing can be started.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabIntegrationTests: XCTestCase {

    func testDashboardStopReachesComposer2BeforeStudioAndOnlyWhenOwned() async {
        let orchestrator = UnifiedOrchestrator()
        var composerTargets: [UnifiedOrchestrator.LiveEffectStopTarget] = []
        var studioTargets: [UnifiedOrchestrator.LiveEffectStopTarget] = []
        var owns = true
        orchestrator.composer2StopHandler = { target in
            composerTargets.append(target)
            return owns
        }
        orchestrator.studioStopHandler = { target in studioTargets.append(target) }

        await orchestrator.requestNowPlayingStop(bridgeID: "b1", roomID: "r1")
        XCTAssertEqual(composerTargets.count, 1)
        XCTAssertEqual(composerTargets[0].bridgeID, "b1")
        XCTAssertEqual(composerTargets[0].roomID, "r1")
        XCTAssertTrue(composerTargets[0].turnOffLights)
        XCTAssertTrue(studioTargets.isEmpty, "a stop Composer 2 owned never reaches Studio")

        owns = false
        await orchestrator.requestNowPlayingStop(bridgeID: "b1", roomID: "r2", turnOffLights: false)
        XCTAssertEqual(composerTargets.count, 2)
        XCTAssertEqual(studioTargets.count, 1, "a row Composer 2 does not own falls through to Studio")
        XCTAssertEqual(studioTargets[0].roomID, "r2")
        XCTAssertFalse(studioTargets[0].turnOffLights)

        await orchestrator.requestNowPlayingStop(roomID: "r3")
        XCTAssertEqual(composerTargets.last?.bridgeID, nil, "the room-only compatibility stop is routed too")
        XCTAssertEqual(studioTargets.count, 2)

        orchestrator.composer2StopHandler = nil
        await orchestrator.requestNowPlayingStop(bridgeID: "b1", roomID: "r1")
        XCTAssertEqual(composerTargets.count, 3, "cleared handler: nothing more is asked of Composer 2")
        XCTAssertEqual(studioTargets.count, 3)
    }

    func testEntryStopRouteGoesThroughTheSameHandler() async {
        let orchestrator = UnifiedOrchestrator()
        var seen: [String] = []
        orchestrator.composer2StopHandler = { target in seen.append("\(target.bridgeID ?? "-")/\(target.roomID)"); return true }
        let entry = ActiveEffectEntry(liveBridgeID: "b1", roomID: "r1", roomName: "Room", groupedLightID: "g",
                                      effectID: "composer2", effectName: "Aurora", effectIcon: "sparkles", isAppDriven: true)
        await orchestrator.requestNowPlayingStop(entry)
        XCTAssertEqual(seen, ["b1/r1"])
    }

    func testGatewayPublishesAndRetiresNowPlayingRows() async {
        let orchestrator = UnifiedOrchestrator()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        gateway.publishNowPlaying(roomID: "r1", bridgeID: "b1", roomName: "Living", groupedLightID: "g1",
                                  compositionName: "Aurora Drift")
        let rows = orchestrator.activeEffectEntries.filter { $0.effectID == "composer2" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].roomID, "r1")
        XCTAssertEqual(rows[0].bridgeID, "b1")
        XCTAssertEqual(rows[0].effectName, "Aurora Drift")
        XCTAssertTrue(rows[0].isAppDriven, "the Dashboard knows a loop is running")

        gateway.publishNowPlaying(roomID: "r1", bridgeID: "b1", roomName: "Living", groupedLightID: "g1",
                                  compositionName: "Lava Lamp")
        let renamed = orchestrator.activeEffectEntries.filter { $0.effectID == "composer2" }
        XCTAssertEqual(renamed.count, 1, "republishing the same room replaces the row")
        XCTAssertEqual(renamed[0].effectName, "Lava Lamp")

        gateway.retireNowPlaying(roomID: "r1", bridgeID: "b1")
        XCTAssertTrue(orchestrator.activeEffectEntries.filter { $0.effectID == "composer2" }.isEmpty)
        gateway.retireNowPlaying(roomID: "r1", bridgeID: "b1")
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty, "retiring twice is harmless")
    }

    /// A Studio look that replaced ours publishes under the same room key;
    /// retiring OUR row must leave THEIRS on the Dashboard.
    func testRetiringNeverRemovesTheReplacementsRow() async {
        let orchestrator = UnifiedOrchestrator()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        gateway.publishNowPlaying(roomID: "r1", bridgeID: "b1", roomName: "Living", groupedLightID: "g1",
                                  compositionName: "Aurora Drift")
        orchestrator.addActiveEffect(ActiveEffectEntry(
            liveBridgeID: "b1", roomID: "r1", roomName: "Living", groupedLightID: "g1",
            effectID: "party", effectName: "Party", effectIcon: "sparkles", isAppDriven: true))
        XCTAssertEqual(orchestrator.activeEffectEntries.map(\.effectID), ["party"], "same key: the replacement's row won")
        gateway.retireNowPlaying(roomID: "r1", bridgeID: "b1")
        XCTAssertEqual(orchestrator.activeEffectEntries.map(\.effectID), ["party"], "and it survives our retirement")
    }

    func testGatewayInstallsAndClearsTheStopHandler() async {
        let orchestrator = UnifiedOrchestrator()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        XCTAssertNil(orchestrator.composer2StopHandler)
        var calls: [(String?, String)] = []
        gateway.installStopHandler { bridgeID, roomID in calls.append((bridgeID, roomID)); return true }
        XCTAssertNotNil(orchestrator.composer2StopHandler)
        await orchestrator.requestNowPlayingStop(bridgeID: "b1", roomID: "r1")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "b1")
        XCTAssertEqual(calls[0].1, "r1")
        gateway.installStopHandler(nil)
        XCTAssertNil(orchestrator.composer2StopHandler)
    }

    func testAttendedStartWithNoBridgeFailsWithoutAskingOrMutating() async {
        let orchestrator = UnifiedOrchestrator()
        let room = Composer2LabFixtures.room("r1")
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        var asked = false
        let outcome = await orchestrator.startCompositionModeAttended(
            room: room, paramBox: box, preferEntertainment: true, askTakeover: { asked = true; return true })
        guard case .failed = outcome else { return XCTFail("expected a failure without a bridge, got \(outcome)") }
        XCTAssertFalse(asked, "no controller was found, so no question was asked")
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty)
        XCTAssertNil(orchestrator.compositionTransportByRoom["r1"])
    }

    func testGatewayStartMapsRefusalsWithoutTouchingTheRegistry() async {
        let orchestrator = UnifiedOrchestrator()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        let room = Composer2LabFixtures.room("r1")
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        let outcome = await gateway.start(room: room, box: box, preferStreaming: true, askTakeover: { true })
        guard case .failed(let message) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty, "a failed start publishes no row")
        XCTAssertEqual(gateway.gate(for: room), .noBridge)
        XCTAssertEqual(gateway.gate(for: nil), .noRoom)
    }

    func testDeclinedTakeoverCopyIsTheSameEverywhere() {
        XCTAssertEqual(Composer2Copy.takeoverDeclined, EntertainmentConsentCopy.takeoverDeclined)
        XCTAssertFalse(Composer2Copy.takeoverDeclined.isEmpty)
    }
}
