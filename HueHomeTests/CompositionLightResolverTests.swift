import XCTest
@testable import HueHome

final class CompositionLightResolverTests: XCTestCase {
    private func light(
        id: String,
        ownerRID: String? = nil
    ) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: "L-\(id)", archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 50),
            color: nil,
            color_temperature: nil,
            owner: ownerRID.map { ResourceRef(rid: $0, rtype: "device") }
        )
    }

    private func refs(_ entries: [(String, String)]) -> [(rid: String, rtype: String)] {
        entries.map { (rid: $0.0, rtype: $0.1) }
    }

    // MARK: - Direct mode detection

    func testHasDirectLightReferences_noDirectLightRef_returnsFalse() {
        XCTAssertFalse(
            CompositionLightResolver.hasDirectLightReferences(
                childResourceRefs: refs([("device-1", "device"), ("device-2", "device")])
            )
        )
    }

    func testHasDirectLightReferences_oneDirectLightRef_returnsTrue() {
        XCTAssertTrue(
            CompositionLightResolver.hasDirectLightReferences(
                childResourceRefs: refs([("light-1", "light")])
            )
        )
    }

    func testHasDirectLightReferences_mixedLightAndDevice_returnsTrue() {
        XCTAssertTrue(
            CompositionLightResolver.hasDirectLightReferences(
                childResourceRefs: refs([("device-1", "device"), ("light-1", "light")])
            )
        )
    }

    // MARK: - resolveLightIDs direct mode

    func testResolveLightIDs_directMode_preservesOrderDuplicates_andIgnoresNonLight() {
        let childRefs = refs([
            ("light-2", "light"),
            ("device-1", "device"),
            ("light-1", "light"),
            ("light-2", "light"),
        ])

        let result = CompositionLightResolver.resolveLightIDs(
            childResourceRefs: childRefs,
            lights: []
        )

        XCTAssertEqual(result, ["light-2", "light-1", "light-2"])
    }

    func testResolveLightIDs_directMode_doesNotRequireLights() {
        let result = CompositionLightResolver.resolveLightIDs(
            childResourceRefs: refs([("light-a", "light"), ("light-b", "light")]),
            lights: []
        )
        XCTAssertEqual(result, ["light-a", "light-b"])
    }

    func testResolveLightIDs_emptyRefs_returnsEmpty() {
        XCTAssertEqual(
            CompositionLightResolver.resolveLightIDs(childResourceRefs: [], lights: [light(id: "x")]),
            []
        )
    }

    // MARK: - resolveLights direct mode

    func testResolveLights_directMode_usesFetchedLightOrderingNotRefOrdering() {
        let childRefs = refs([("light-b", "light"), ("light-a", "light")])
        let lights = [light(id: "light-a"), light(id: "light-b")]

        let result = CompositionLightResolver.resolveLights(
            childResourceRefs: childRefs,
            lights: lights
        )

        XCTAssertEqual(result.map(\.id), ["light-a", "light-b"])
    }

    func testResolveLights_directMode_deduplicatesRepeatedRefs_andOmitsMissing() {
        let childRefs = refs([("light-a", "light"), ("light-a", "light"), ("light-missing", "light")])
        let lights = [light(id: "light-a"), light(id: "light-b")]

        let result = CompositionLightResolver.resolveLights(
            childResourceRefs: childRefs,
            lights: lights
        )

        XCTAssertEqual(result.map(\.id), ["light-a"])
    }

    func testResolveLights_directMode_ignoresOwnerFallbackWhenMixed() {
        let childRefs = refs([("light-direct", "light"), ("device-1", "device")])
        let lights = [
            light(id: "light-owner", ownerRID: "device-1"),
            light(id: "light-direct", ownerRID: "device-2"),
        ]

        let result = CompositionLightResolver.resolveLights(
            childResourceRefs: childRefs,
            lights: lights
        )

        XCTAssertEqual(result.map(\.id), ["light-direct"])
    }

    func testResolveLights_emptyRefs_returnsEmpty() {
        XCTAssertEqual(
            CompositionLightResolver.resolveLights(
                childResourceRefs: [],
                lights: [light(id: "light-a", ownerRID: "device-1")]
            ).map(\.id),
            []
        )
    }

    // MARK: - Device-owner fallback

    func testResolveLights_ownerFallback_matchesOwnerRID_andOmitNonMatchesAndNilOwners() {
        let childRefs = refs([("device-2", "device"), ("device-1", "device"), ("device-1", "device")])
        let lights = [
            light(id: "light-a", ownerRID: "device-1"),
            light(id: "light-b", ownerRID: "device-2"),
            light(id: "light-c", ownerRID: "device-3"),
            light(id: "light-d", ownerRID: nil),
        ]

        let result = CompositionLightResolver.resolveLights(
            childResourceRefs: childRefs,
            lights: lights
        )

        XCTAssertEqual(result.map(\.id), ["light-a", "light-b"])
    }

    func testResolveLightIDs_ownerFallback_returnsFetchedLightOrder_withoutDuplicates() {
        let childRefs = refs([("device-2", "device"), ("device-1", "device"), ("device-1", "device")])
        let lights = [
            light(id: "light-z", ownerRID: "device-1"),
            light(id: "light-a", ownerRID: "device-2"),
            light(id: "light-x", ownerRID: "device-9"),
        ]

        let result = CompositionLightResolver.resolveLightIDs(
            childResourceRefs: childRefs,
            lights: lights
        )

        XCTAssertEqual(result, ["light-z", "light-a"])
    }

    // MARK: - Edge cases

    func testEmptyLightsReturnsEmptyOutputs() {
        let deviceRefs = refs([("device-1", "device")])
        XCTAssertEqual(
            CompositionLightResolver.resolveLights(childResourceRefs: deviceRefs, lights: []).map(\.id),
            []
        )
        XCTAssertEqual(
            CompositionLightResolver.resolveLightIDs(childResourceRefs: deviceRefs, lights: []),
            []
        )
    }

    func testNonMatchingRefsReturnEmptyOutputs() {
        let childRefs = refs([("device-missing", "device")])
        let lights = [light(id: "light-a", ownerRID: "device-1")]

        XCTAssertEqual(
            CompositionLightResolver.resolveLights(childResourceRefs: childRefs, lights: lights).map(\.id),
            []
        )
        XCTAssertEqual(
            CompositionLightResolver.resolveLightIDs(childResourceRefs: childRefs, lights: lights),
            []
        )
    }

    func testRepeatedIdenticalInputsReturnIdenticalOutputs() {
        let childRefs = refs([("light-a", "light"), ("light-b", "light")])
        let lights = [light(id: "light-b"), light(id: "light-a")]

        let firstLights = CompositionLightResolver.resolveLights(childResourceRefs: childRefs, lights: lights).map(\.id)
        let secondLights = CompositionLightResolver.resolveLights(childResourceRefs: childRefs, lights: lights).map(\.id)
        let firstIDs = CompositionLightResolver.resolveLightIDs(childResourceRefs: childRefs, lights: lights)
        let secondIDs = CompositionLightResolver.resolveLightIDs(childResourceRefs: childRefs, lights: lights)

        XCTAssertEqual(firstLights, secondLights)
        XCTAssertEqual(firstIDs, secondIDs)
    }

    func testInputArraysRemainUnchanged() {
        let childRefs = refs([("light-a", "light"), ("device-1", "device")])
        let lights = [light(id: "light-a", ownerRID: "device-1"), light(id: "light-b", ownerRID: nil)]

        let refsSnapshot = childRefs.map { "\($0.rid)|\($0.rtype)" }
        let lightsSnapshot = lights.map { "\($0.id)|\($0.owner?.rid ?? "")" }

        _ = CompositionLightResolver.resolveLights(childResourceRefs: childRefs, lights: lights)
        _ = CompositionLightResolver.resolveLightIDs(childResourceRefs: childRefs, lights: lights)

        XCTAssertEqual(childRefs.map { "\($0.rid)|\($0.rtype)" }, refsSnapshot)
        XCTAssertEqual(lights.map { "\($0.id)|\($0.owner?.rid ?? "")" }, lightsSnapshot)
    }
}
