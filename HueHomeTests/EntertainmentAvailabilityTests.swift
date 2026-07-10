// EntertainmentAvailabilityTests.swift
// ChromaGlow — Studio transport
//
// Before this type existed, a room that could not stream still offered
// "Entertainment Area (Streaming)"; the only feedback was the effect quietly
// demoting to REST after you picked it. Gating the option means we now have the
// opposite risk — disabling a transport that would actually have worked.
//
// These lock the rule that resolves that tension: we only ever say no when we
// know. An unasked bridge offers streaming and lets startCompositionMode fall
// back, because a false "unavailable" is worse than a fallback the user never
// sees.

import XCTest
@testable import HueHome

final class EntertainmentAvailabilityTests: XCTestCase {

    private typealias Availability = UnifiedOrchestrator.EntertainmentAvailability

    /// The whole point: never disable a transport we have not actually checked.
    func testUnknownOffersStreamingRatherThanGuessingNo() {
        XCTAssertTrue(Availability.unknown.canStream)
        XCTAssertNil(Availability.unknown.reason, "nothing to explain — we haven't looked")
    }

    func testAvailableStreamsAndNeedsNoExplanation() {
        let availability = Availability.available(areaName: "Living Room TV")
        XCTAssertTrue(availability.canStream)
        XCTAssertNil(availability.reason)
    }

    /// A definite no must both block the option and say why, or the user is
    /// left with a greyed-out row and no recourse.
    func testEveryDefiniteNoBlocksStreamingAndExplainsItself() {
        for availability in [Availability.noClientKey, .noArea, .noBridge] {
            XCTAssertFalse(availability.canStream, "\(availability) should not stream")
            let reason = availability.reason
            XCTAssertNotNil(reason, "\(availability) must explain itself")
            XCTAssertFalse(reason?.isEmpty ?? true)
        }
    }

    /// The reasons are shown verbatim in a menu section, so they should read as
    /// sentences that tell the user what to do next.
    func testReasonsNameTheirRemedy() {
        XCTAssertTrue(Availability.noClientKey.reason?.contains("Re-pair") ?? false,
                      "a missing client key is fixed by re-pairing; say so")
        XCTAssertTrue(Availability.noArea.reason?.contains("entertainment area") ?? false)
    }

    func testAreaNameDistinguishesAvailability() {
        XCTAssertNotEqual(Availability.available(areaName: "Den"),
                          Availability.available(areaName: "Kitchen"))
        XCTAssertEqual(Availability.available(areaName: "Den"),
                       Availability.available(areaName: "Den"))
    }
}
