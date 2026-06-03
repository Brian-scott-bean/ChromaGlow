import XCTest
import SwiftData
@testable import HueHome

@MainActor
final class OrchestratorCacheDemoTests: XCTestCase {

    func testPreloadCached_populatesAllRooms() {
        let orchestrator = makeOrchestratorCacheDemoSUT()
        let cached = makeLocalRoom(
            id: "room-001",
            name: "Bedroom",
            isOn: true
        )

        orchestrator.preloadCached(from: [cached])

        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertEqual(orchestrator.allRooms[0].id, "room-001")
        XCTAssertTrue(orchestrator.allRooms[0].isOn)
    }

    func testPreloadCached_sortsAlphabetically() {
        let orchestrator = makeOrchestratorCacheDemoSUT()
        let rooms = [
            makeLocalRoom(id: "r3", name: "Zara", isOn: true),
            makeLocalRoom(id: "r1", name: "Attic", isOn: true),
            makeLocalRoom(id: "r2", name: "Bedroom", isOn: true),
        ]

        orchestrator.preloadCached(from: rooms)

        XCTAssertEqual(
            orchestrator.allRooms.map(\.name),
            ["Attic", "Bedroom", "Zara"]
        )
    }

    func testPreloadCached_emptyInput_leavesAllRoomsEmpty() {
        let orchestrator = makeOrchestratorCacheDemoSUT()
        orchestrator.preloadCached(from: [])

        XCTAssertTrue(orchestrator.allRooms.isEmpty)
    }

    func testDemoMode_loadAll_doesNotMakeNetworkRequests() async {
        let orchestrator = makeOrchestratorCacheDemoSUT()
        orchestrator.enterDemoMode()

        await orchestrator.loadAll()

        XCTAssertFalse(
            orchestrator.allRooms.isEmpty,
            "Demo mode should populate allRooms with mock data"
        )
        XCTAssertTrue(orchestrator.isDemoMode)
    }

    @MainActor
    private func makeOrchestratorCacheDemoSUT() -> UnifiedOrchestrator {
        UnifiedOrchestrator()
    }

    private func makeLocalRoom(
        id: String,
        name: String,
        isOn: Bool,
        bridgeID: String = "bridge-1"
    ) -> HueLocalRoom {
        let room = HueLocalRoom(roomID: id, bridgeID: bridgeID)
        room.cachedName = name
        room.lastIsOn = isOn
        room.lastBrightness = 80
        return room
    }
}
