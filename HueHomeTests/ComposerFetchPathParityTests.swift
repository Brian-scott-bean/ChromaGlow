import XCTest
@testable import HueHome

// MARK: - Fetch-counting spy

private final class ComposerFetchCountingAPIClient: HueAPIClient {
    private(set) var fetchLightsCallCount = 0
    var stubLights: [HueLight] = []
    var shouldThrow = false

    override init() {
        super.init(ip: "test-ip", token: "test-token")
    }

    override func fetchLights() async throws -> [HueLight] {
        fetchLightsCallCount += 1
        if shouldThrow {
            throw HueAPIError.httpError(500)
        }
        return stubLights
    }
}

// MARK: - ComposerFetchPathParityTests

@MainActor
final class ComposerFetchPathParityTests: XCTestCase {
    private let orchestrator = UnifiedOrchestrator()

    private func refs(_ entries: [(String, String)]) -> [(rid: String, rtype: String)] {
        entries.map { (rid: $0.0, rtype: $0.1) }
    }

    private func room(childResourceRefs: [(rid: String, rtype: String)]) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: "room-test",
            name: "Test Room",
            archetype: "bedroom",
            isOn: true,
            brightness: 50,
            groupedLightID: "gl-test",
            lightCount: childResourceRefs.count,
            bridgeID: "bridge-test",
            childResourceRefs: childResourceRefs
        )
    }

    private func light(
        id: String,
        ownerRID: String? = nil,
        gamutType: String? = nil
    ) -> HueLight {
        let color: LightColor? = gamutType.map {
            LightColor(
                xy: CIExy(x: 0.3, y: 0.3),
                gamut_type: $0
            )
        }
        return HueLight(
            id: id,
            metadata: LightMetadata(name: "L-\(id)", archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 50),
            color: color,
            color_temperature: nil,
            owner: ownerRID.map { ResourceRef(rid: $0, rtype: "device") }
        )
    }

    // MARK: - ID resolution (resolveCompositionLightIDs)

    func testID01_emptyRefs_zeroFetches_emptyIDs() async {
        let api = ComposerFetchCountingAPIClient()
        let result = await orchestrator.testResolveCompositionLightIDs(
            for: room(childResourceRefs: []),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 0)
        XCTAssertEqual(result, [])
    }

    func testID02_directRefs_zeroFetches_preservesOrderAndDuplicates() async {
        let api = ComposerFetchCountingAPIClient()
        let childRefs = refs([
            ("L2", "light"),
            ("L1", "light"),
            ("L2", "light"),
        ])
        let result = await orchestrator.testResolveCompositionLightIDs(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 0)
        XCTAssertEqual(result, ["L2", "L1", "L2"])
    }

    func testID03_mixedRefs_zeroFetches_directIDsOnly() async {
        let api = ComposerFetchCountingAPIClient()
        let childRefs = refs([
            ("light-direct", "light"),
            ("device-1", "device"),
        ])
        let result = await orchestrator.testResolveCompositionLightIDs(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 0)
        XCTAssertEqual(result, ["light-direct"])
    }

    func testID04_ownerFallbackSuccess_oneFetch_preservesFetchedOrder() async {
        let api = ComposerFetchCountingAPIClient()
        api.stubLights = [
            light(id: "light-z", ownerRID: "device-1"),
            light(id: "light-a", ownerRID: "device-2"),
            light(id: "light-x", ownerRID: "device-9"),
        ]
        let childRefs = refs([
            ("device-2", "device"),
            ("device-1", "device"),
            ("device-1", "device"),
        ])
        let result = await orchestrator.testResolveCompositionLightIDs(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, ["light-z", "light-a"])
    }

    func testID05_ownerFallbackFailure_oneFetch_emptyIDs() async {
        let api = ComposerFetchCountingAPIClient()
        api.shouldThrow = true
        let childRefs = refs([("device-1", "device")])
        let result = await orchestrator.testResolveCompositionLightIDs(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, [])
    }

    // MARK: - Gamut resolution (resolveCompositionGamut)

    func testGAM01_directRefs_oneFetch_majorityGamutA() async {
        let api = ComposerFetchCountingAPIClient()
        let childRefs = refs([
            ("L1", "light"),
            ("L2", "light"),
            ("L3", "light"),
        ])
        api.stubLights = [
            light(id: "L1", gamutType: "A"),
            light(id: "L2", gamutType: "A"),
            light(id: "L3", gamutType: "B"),
        ]
        let result = await orchestrator.testResolveCompositionGamut(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, .a)
    }

    func testGAM02_ownerFallback_oneFetch_majorityGamutB() async {
        let api = ComposerFetchCountingAPIClient()
        let childRefs = refs([
            ("device-1", "device"),
            ("device-2", "device"),
        ])
        api.stubLights = [
            light(id: "light-a", ownerRID: "device-1", gamutType: "B"),
            light(id: "light-b", ownerRID: "device-2", gamutType: "B"),
            light(id: "light-c", ownerRID: "device-2", gamutType: "A"),
        ]
        let result = await orchestrator.testResolveCompositionGamut(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, .b)
    }

    func testGAM03_fetchFailure_oneFetch_returnsGamutC() async {
        let api = ComposerFetchCountingAPIClient()
        api.shouldThrow = true
        let childRefs = refs([("L1", "light")])
        let result = await orchestrator.testResolveCompositionGamut(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, .c)
    }

    func testGAM04_emptyResolvedLights_oneFetch_returnsGamutC() async {
        let api = ComposerFetchCountingAPIClient()
        let childRefs = refs([("device-missing", "device")])
        api.stubLights = [
            light(id: "light-a", ownerRID: "device-1", gamutType: "A"),
        ]
        let result = await orchestrator.testResolveCompositionGamut(
            for: room(childResourceRefs: childRefs),
            api: api
        )
        XCTAssertEqual(api.fetchLightsCallCount, 1)
        XCTAssertEqual(result, .c)
    }
}
