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
        for availability in [Availability.noClientKey, .noArea, .noMatchingArea, .noBridge] {
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
        XCTAssertTrue(Availability.noMatchingArea.reason?.contains("Create or update") ?? false,
                      "a room outside every area is fixed by making one FOR that room")
    }

    /// "No area on this bridge" and "no area for this room" are different
    /// sentences with different remedies. Telling someone with three areas that
    /// they have none sends them to build a fourth.
    func testNoMatchingAreaIsNotTheSameAnswerAsNoArea() {
        XCTAssertNotEqual(Availability.noArea, Availability.noMatchingArea)
        XCTAssertNotEqual(Availability.noArea.reason, Availability.noMatchingArea.reason)
        XCTAssertFalse(Availability.noMatchingArea.reason?.contains("has no entertainment area") ?? true,
                       "must not claim the bridge is arealess when it has areas for other rooms")
    }

    func testAreaNameDistinguishesAvailability() {
        XCTAssertNotEqual(Availability.available(areaName: "Den"),
                          Availability.available(areaName: "Kitchen"))
        XCTAssertEqual(Availability.available(areaName: "Den"),
                       Availability.available(areaName: "Den"))
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Packet 7 follow-up: a cached "no" may not disable its own remedy
    // ═══════════════════════════════════════════════════════════
    //
    // The on-device defect. `entertainmentAvailability` is a CACHE read, and
    // the transport row was `.disabled(!availability.canStream)` against it —
    // while tapping that very row was the only thing in the app that ever
    // refreshed the cache. Create an Entertainment Area in the official Hue
    // app and ChromaGlow answered "no area" until it was force-quit, which
    // made packet 7's whole takeover prompt unreachable on real hardware.
    //
    // The behavioural half of this lives in `EntertainmentRobustnessTests`
    // (invalidation, forced refresh, frozen plans). These two pin the SHAPE of
    // the two surfaces, because the defect was a view modifier — no amount of
    // orchestrator coverage can see it.

    /// The comment-only lines are stripped first: the fix deliberately left a
    /// prose explanation where the modifier used to be, and a source-shape test
    /// that reads its own rationale as a violation would fail on the fix.
    private func viewSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Both surfaces that offer streaming, so neither can regress alone.
    private static let transportSurfaces = [
        "HueHome/UI/Studio/StudioView.swift",
        "HueHome/UI/Studio/MixerTrayView.swift",
    ]

    private func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    /// P7F-01
    /// Pins the exact device defect: a cached verdict disabled the only control
    /// that would have refreshed it, so the app could never learn it was wrong.
    func testTheStreamingActionIsNeverDisabledByCachedAvailability() throws {
        for path in Self.transportSurfaces {
            let source = try viewSource(path)
            let offenders = matches(#"\.disabled\([^)]*canStream[^)]*\)"#, in: source)
            XCTAssertTrue(offenders.isEmpty, """
                \(path) still gates a control on the cached streaming verdict: \
                \(offenders.joined(separator: " | ")) — tapping that control is \
                what refreshes the cache, so disabling it makes a stale "no" \
                permanent until a force-quit
                """)
        }
    }

    /// P7F-02
    /// The other half of the same fix, and the one that is easy to lose while
    /// deleting the modifier: dropping the gate must not also drop the
    /// explanation, or a streaming request that falls back to Room mode becomes
    /// silent again.
    func testACachedNoStillExplainsItselfOnBothTransportSurfaces() throws {
        for path in Self.transportSurfaces {
            let source = try viewSource(path)
            XCTAssertTrue(source.contains("availability.reason"), """
                \(path) no longer reads the availability reason — the row is \
                tappable now, so this sentence is the ONLY thing telling the \
                user why streaming is expected to fail
                """)
            XCTAssertTrue(source.contains("Section(reason)"), """
                \(path) no longer renders the reason as a menu section footer
                """)
        }

        // And the value side of the same contract: there is always something to
        // render for a definite no, and never anything to render otherwise.
        for availability in [Availability.noClientKey, .noArea, .noMatchingArea, .noBridge] {
            XCTAssertNotNil(availability.reason,
                            "\(availability) is a definite no with nothing to show in the footer")
        }
        XCTAssertNil(Availability.unknown.reason,
                     "an unasked bridge has no complaint to render")
        XCTAssertNil(Availability.available(areaName: "Den").reason,
                     "a working area has no complaint to render")
    }

    /// P7F-03
    /// The three refusals are the only words a user gets when an explicit
    /// streaming request is not honoured. "There's no compatible Entertainment
    /// Area" alone leaves the app playing something the user never chose and
    /// never heard about — the transport change is the part that has to be said.
    func testTheHonestAvailabilityAnswersNameTheirConsequence() {
        XCTAssertTrue(EntertainmentAvailabilityCopy.noCompatibleArea.contains("Room mode"), """
            the fallback answer must name Room mode: an explanation that omits \
            the transport change is still an unexplained fallback
            """)

        let protocolVocabulary = [
            "REST", "DTLS", "API", "configuration ID",
            "entertainment_configuration", "session registry", "refcount",
        ]
        let strings: [(name: String, text: String)] = [
            ("noCompatibleArea", EntertainmentAvailabilityCopy.noCompatibleArea),
            ("noCompatibleAreaNothingChanged",
             EntertainmentAvailabilityCopy.noCompatibleAreaNothingChanged),
            ("couldNotCheck", EntertainmentAvailabilityCopy.couldNotCheck),
            ("couldNotStart", EntertainmentAvailabilityCopy.couldNotStart),
        ]
        for (name, text) in strings {
            XCTAssertFalse(text.isEmpty, "\(name) must actually say something")
            for term in protocolVocabulary {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(term),
                    "\(name) leaks protocol vocabulary '\(term)' — the reader owns lights, not a streaming stack: \(text)")
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Composer 2 packet 1b: which area belongs to which room
// ═══════════════════════════════════════════════════════════════════════
//
// The defect these lock down: selection was scoped to the BRIDGE
// (`configs.first`), so a Bedroom composition could open a DTLS session on the
// Living Room's Entertainment Area and light the wrong room.
//
// The trap underneath it: `EntertainmentChannel.lightServiceIDs` holds
// *entertainment service* rids, not light rids. A selector that compares them
// with room light IDs directly matches nothing, anywhere, and disables
// Entertainment app-wide while every test written against the same wrong
// assumption still passes. So these tests build the map the way production
// does — from raw `/resource/entertainment` JSON joined to `HueLight.owner` —
// rather than handing the selector an already-resolved answer.

final class EntertainmentAreaSelectorTests: XCTestCase {

    private typealias Selector = EntertainmentAreaSelector

    // ── Fixtures ──────────────────────────────────────────────

    /// A config whose channels reference entertainment services `entIDs`,
    /// one channel per service so channel IDs stay unique and valid.
    private func config(_ id: String, _ name: String, ent entIDs: [String]) -> EntertainmentConfig {
        EntertainmentConfig(
            id: id,
            name: name,
            channels: entIDs.enumerated().map { index, entID in
                EntertainmentChannel(
                    id: index,
                    lightServiceIDs: [entID],
                    position: (x: Double(index), y: 0, z: 0)
                )
            }
        )
    }

    private func channel(_ id: Int, ent entIDs: [String] = ["E1"]) -> EntertainmentChannel {
        EntertainmentChannel(id: id, lightServiceIDs: entIDs, position: (x: 0, y: 0, z: 0))
    }

    private func light(_ id: String, device: String) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 100),
            color: nil,
            color_temperature: nil,
            owner: ResourceRef(rid: device, rtype: "device")
        )
    }

    /// Raw `GET /clip/v2/resource/entertainment` payload.
    private func entServicesJSON(_ pairs: [(ent: String, device: String)]) -> Data {
        let items = pairs.map { #"{"id":"\#($0.ent)","owner":{"rid":"\#($0.device)","rtype":"device"}}"# }
        return Data(#"{"data":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// The production join: entertainment service → owner device → light service.
    private func map(_ pairs: [(ent: String, device: String, light: String)]) -> [String: String] {
        Selector.entertainmentToLightMap(
            entertainmentServiceOwners: Selector.entertainmentServiceOwners(
                from: entServicesJSON(pairs.map { (ent: $0.ent, device: $0.device) })
            ),
            lights: pairs.map { light($0.light, device: $0.device) }
        )
    }

    /// E1→L1, E2→L2, … through real devices.
    private func straightMap(_ count: Int) -> [String: String] {
        map((1...count).map { (ent: "E\($0)", device: "D\($0)", light: "L\($0)") })
    }

    // ── The mapping itself ────────────────────────────────────

    /// Proves the join rather than assuming it: E1 and L1 are related ONLY by
    /// both naming device D1 as their owner. Nothing in the ids matches.
    func testEntertainmentServiceResolvesToItsLightThroughTheOwnerDevice() {
        let resolved = Selector.entertainmentToLightMap(
            entertainmentServiceOwners: Selector.entertainmentServiceOwners(
                from: entServicesJSON([(ent: "ent-aaa", device: "dev-111")])
            ),
            lights: [light("light-zzz", device: "dev-111")]
        )
        XCTAssertEqual(resolved, ["ent-aaa": "light-zzz"],
            "entertainment service → owner device → light service is the only valid route")
    }

    /// The failure mode packet 1a caught before it shipped: comparing the
    /// entertainment rid directly with light IDs matches nothing.
    func testEntertainmentServiceIDsAreNotLightIDs() {
        let resolved = map([(ent: "ent-aaa", device: "dev-111", light: "light-zzz")])
        XCTAssertNil(resolved["light-zzz"], "a light rid is not a key in this map")
        XCTAssertFalse(resolved.values.contains("ent-aaa"), "an entertainment rid is not a light")
    }

    func testAnEntertainmentServiceWithNoMatchingLightOwnerIsDroppedNotGuessed() {
        let resolved = Selector.entertainmentToLightMap(
            entertainmentServiceOwners: Selector.entertainmentServiceOwners(
                from: entServicesJSON([(ent: "E1", device: "D1"), (ent: "E-orphan", device: "D-gone")])
            ),
            lights: [light("L1", device: "D1")]
        )
        XCTAssertEqual(resolved, ["E1": "L1"], "a stale member must not manufacture a match")
    }

    /// A stale member must not be able to defeat an otherwise exact match.
    func testAStaleMemberIsIgnoredSafelyRatherThanBlockingSelection() {
        let membership = map([(ent: "E1", device: "D1", light: "L1"),
                              (ent: "E2", device: "D2", light: "L2")])
        // E-ghost resolves to nothing at all.
        let area = config("area", "Bedroom", ent: ["E1", "E2", "E-ghost"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [area],
                            entertainmentToLightMap: membership)?.id,
            "area")
    }

    /// A device owning two light services must resolve the same way regardless
    /// of the order `/resource/light` came back in — otherwise the whole
    /// selection depends on bridge response order.
    func testMultiLightDeviceCollapsesDeterministically() {
        let forward = Selector.deviceToLightID(lights: [light("L-a", device: "D1"), light("L-b", device: "D1")])
        let reversed = Selector.deviceToLightID(lights: [light("L-b", device: "D1"), light("L-a", device: "D1")])
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward["D1"], "L-a")
    }

    func testMalformedEntertainmentPayloadYieldsAnEmptyMapNotACrash() {
        XCTAssertTrue(Selector.entertainmentServiceOwners(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(Selector.entertainmentServiceOwners(from: Data(#"{"data":[{"id":"E1"}]}"#.utf8)).isEmpty,
                      "an entry with no owner has no device to join through")
    }

    // ── Stage A: exact match ──────────────────────────────────

    /// MANDATORY positive case. An always-nil selector would disable
    /// Entertainment everywhere and still pass every negative test.
    func testExactMatchIsSelected() {
        let area = config("area-1", "Bedroom", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [area],
                            entertainmentToLightMap: straightMap(2))?.id,
            "area-1")
    }

    /// The literal defect: the bridge lists another room's area first.
    func testAnotherRoomsAreaListedFirstIsNotSelected() {
        let other = config("living", "Living Room", ent: ["E3", "E4"])
        let mine = config("bedroom", "Bedroom", ent: ["E1", "E2"])
        let selected = Selector.select(roomLightIDs: ["L1", "L2"],
                                       configs: [other, mine],
                                       entertainmentToLightMap: straightMap(4))
        XCTAssertEqual(selected?.id, "bedroom", "position in the bridge response is not evidence")
    }

    func testSelectionIsIndependentOfConfigOrder() {
        let other = config("living", "Living Room", ent: ["E3", "E4"])
        let mine = config("bedroom", "Bedroom", ent: ["E1", "E2"])
        let membership = straightMap(4)
        let forward = Selector.select(roomLightIDs: ["L1", "L2"], configs: [other, mine],
                                      entertainmentToLightMap: membership)
        let reversed = Selector.select(roomLightIDs: ["L1", "L2"], configs: [mine, other],
                                       entertainmentToLightMap: membership)
        XCTAssertEqual(forward?.id, reversed?.id)
        XCTAssertEqual(forward?.id, "bedroom")
    }

    // ── Stage B: an area inside the room ──────────────────────

    func testUniqueLargestSubsetWins() {
        let small = config("small", "Desk", ent: ["E1", "E2"])
        let larger = config("larger", "Bedroom", ent: ["E1", "E2", "E3"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2", "L3", "L4"],
                            configs: [small, larger],
                            entertainmentToLightMap: straightMap(4))?.id,
            "larger")
    }

    func testEquallyLargeDifferentSubsetsAreAmbiguous() {
        let left = config("left", "Left", ent: ["E1", "E2"])
        let right = config("right", "Right", ent: ["E3", "E4"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2", "L3", "L4"],
                            configs: [left, right],
                            entertainmentToLightMap: straightMap(4)),
            "two equally good answers means we do not know the answer")
    }

    /// A deliberate partial area inside a larger room is a normal setup, and
    /// stage B must take it even though it is the only candidate.
    func testALoneAreaContainedInTheRoomIsStillSelected() {
        let partial = config("partial", "TV corner", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2", "L3"],
                            configs: [partial],
                            entertainmentToLightMap: straightMap(3))?.id,
            "partial")
    }

    // ── Stage C: overlap, and only with a real contest ─────────

    func testDominantOverlapWinsWhenItStrictlyContainsEveryRival() {
        // Neither is a subset of the room, so stage B cannot answer.
        let dominant = config("dominant", "Most of the room", ent: ["E1", "E2", "E3", "E9"])
        let lesser = config("lesser", "A corner", ent: ["E1", "E8"])
        let membership = map([
            (ent: "E1", device: "D1", light: "L1"), (ent: "E2", device: "D2", light: "L2"),
            (ent: "E3", device: "D3", light: "L3"), (ent: "E8", device: "D8", light: "L8"),
            (ent: "E9", device: "D9", light: "L9"),
        ])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2", "L3"],
                            configs: [lesser, dominant],
                            entertainmentToLightMap: membership)?.id,
            "dominant")
    }

    func testCompetingIncomparableOverlapsAreAmbiguous() {
        let a = config("a", "A", ent: ["E1", "E2", "E8"])
        let b = config("b", "B", ent: ["E1", "E3", "E9"])
        let membership = map([
            (ent: "E1", device: "D1", light: "L1"), (ent: "E2", device: "D2", light: "L2"),
            (ent: "E3", device: "D3", light: "L3"), (ent: "E8", device: "D8", light: "L8"),
            (ent: "E9", device: "D9", light: "L9"),
        ])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2", "L3"],
                            configs: [a, b],
                            entertainmentToLightMap: membership),
            "{L1,L2} and {L1,L3} are the same size and neither contains the other")
    }

    func testEqualOverlapsCancelEachOtherOut() {
        let a = config("a", "A", ent: ["E1", "E8"])
        let b = config("b", "B", ent: ["E1", "E9"])
        let membership = map([
            (ent: "E1", device: "D1", light: "L1"), (ent: "E8", device: "D8", light: "L8"),
            (ent: "E9", device: "D9", light: "L9"),
        ])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [a, b],
                            entertainmentToLightMap: membership),
            "identical overlaps are a tie, not a winner")
    }

    /// The corner that would have re-created the whole defect: with one
    /// candidate, "strictly contains every OTHER overlap" is vacuously true.
    /// A single whole-house area must NOT be selected for one room inside it.
    func testALoneAreaReachingOutsideTheRoomIsRefused() {
        let wholeHouse = config("house", "Whole House", ent: ["E1", "E2", "E3", "E4"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"],
                            configs: [wholeHouse],
                            entertainmentToLightMap: straightMap(4)),
            "no contest to win — streaming this would light the rest of the house")
    }

    func testNoOverlapAtAllReturnsNil() {
        let elsewhere = config("elsewhere", "Kitchen", ent: ["E3", "E4"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [elsewhere],
                            entertainmentToLightMap: straightMap(4)))
    }

    func testAnEmptyRoomLightSetNeverMatchesAnything() {
        let area = config("area", "Bedroom", ent: ["E1", "E2"])
        XCTAssertNil(Selector.select(roomLightIDs: [], configs: [area],
                                     entertainmentToLightMap: straightMap(2)))
    }

    func testNoConfigsAtAllReturnsNil() {
        XCTAssertNil(Selector.select(roomLightIDs: ["L1"], configs: [],
                                     entertainmentToLightMap: straightMap(1)))
    }

    // ── Duplicate-equivalent areas ────────────────────────────

    /// Hue's app and ChromaGlow's own builder can both define an area over the
    /// same room (a "screen" area and a "music" area). They are equivalent for
    /// room safety, so having both must not disable Entertainment.
    func testTwoAreasOverTheSameLightsStillStream() {
        let screen = config("b-screen", "Bedroom screen", ent: ["E1", "E2"])
        let music = config("a-music", "Bedroom music", ent: ["E2", "E1"])
        let selected = Selector.select(roomLightIDs: ["L1", "L2"],
                                       configs: [screen, music],
                                       entertainmentToLightMap: straightMap(2))
        XCTAssertEqual(selected?.id, "a-music", "tie-break is the stable config ID, not array order")
    }

    func testDuplicateEquivalentAreasSelectTheSameIDInEitherOrder() {
        let screen = config("b-screen", "Bedroom screen", ent: ["E1", "E2"])
        let music = config("a-music", "Bedroom music", ent: ["E1", "E2"])
        let membership = straightMap(2)
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [screen, music],
                            entertainmentToLightMap: membership)?.id,
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [music, screen],
                            entertainmentToLightMap: membership)?.id)
    }

    /// Equivalents are one answer, not two competing ones — they must not add
    /// up to the "real contest" that stage C requires.
    func testDuplicateEquivalentAreasDoNotManufactureAContest() {
        let a = config("a", "House A", ent: ["E1", "E2", "E3"])
        let b = config("b", "House B", ent: ["E3", "E2", "E1"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [a, b],
                            entertainmentToLightMap: straightMap(3)),
            "two copies of one over-wide area are still just one over-wide area")
    }

    func testARepeatedConfigIDIsCountedOnce() {
        let area = config("area", "Bedroom", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [area, area],
                            entertainmentToLightMap: straightMap(2))?.id,
            "area")
    }

    // ── Channel validity gates eligibility ────────────────────

    func testValidatedChannelIDsAcceptsTheFullByteRange() {
        let ok = EntertainmentConfig(id: "c", name: "c", channels: [channel(0), channel(255)])
        XCTAssertEqual(Selector.validatedChannelIDs(for: ok), [0, 255])
    }

    func testValidatedChannelIDsRejectsOutOfRangeAndEmptyAndDuplicates() {
        XCTAssertNil(Selector.validatedChannelIDs(
            for: EntertainmentConfig(id: "c", name: "c", channels: [channel(-1)])))
        XCTAssertNil(Selector.validatedChannelIDs(
            for: EntertainmentConfig(id: "c", name: "c", channels: [channel(256)])))
        XCTAssertNil(Selector.validatedChannelIDs(
            for: EntertainmentConfig(id: "c", name: "c", channels: [])))
        XCTAssertNil(Selector.validatedChannelIDs(
            for: EntertainmentConfig(id: "c", name: "c", channels: [channel(3), channel(3)])),
            "duplicate channel IDs would break the index alignment the motion engines rely on")
    }

    /// A partial stream is not an acceptable degradation: half the area would
    /// light and the rest would sit dark.
    func testOneBadChannelInvalidatesTheWholeConfig() {
        let mixed = EntertainmentConfig(id: "c", name: "c", channels: [channel(0), channel(999)])
        XCTAssertNil(Selector.validatedChannelIDs(for: mixed))
    }

    func testAnAreaThatCannotBeStreamedIsNeverSelected() {
        let unusable = EntertainmentConfig(id: "unusable", name: "Bedroom", channels: [])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [unusable],
                            entertainmentToLightMap: straightMap(2)),
            "promising a stream that startup must refuse is worse than falling back")
    }

    /// The lower ID would win the deterministic tie-break, so eligibility has to
    /// be decided BEFORE ranking or the unusable twin shadows the good one.
    func testAValidDuplicateBeatsAnUnusableLowerIDTwin() {
        let broken = EntertainmentConfig(id: "a-broken", name: "Bedroom", channels: [])
        let working = config("b-working", "Bedroom", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [broken, working],
                            entertainmentToLightMap: straightMap(2))?.id,
            "b-working")
    }

    // ── Preferred config IDs cannot buy their way past room safety ──

    func testAPreferredIDInsideTheWinningGroupIsHonoured() {
        let screen = config("a-screen", "Bedroom screen", ent: ["E1", "E2"])
        let music = config("b-music", "Bedroom music", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [screen, music],
                            entertainmentToLightMap: straightMap(2),
                            preferredConfigID: "b-music")?.id,
            "b-music")
    }

    func testAPreferredIDForAnotherRoomIsRejected() {
        let mine = config("bedroom", "Bedroom", ent: ["E1", "E2"])
        let theirs = config("living", "Living Room", ent: ["E3", "E4"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [mine, theirs],
                            entertainmentToLightMap: straightMap(4),
                            preferredConfigID: "living"),
            "an explicit ID must never be a way to stream into someone else's room")
    }

    func testAPreferredIDThatNamesNothingIsRejected() {
        let mine = config("bedroom", "Bedroom", ent: ["E1", "E2"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [mine],
                            entertainmentToLightMap: straightMap(2),
                            preferredConfigID: "deleted-last-week"))
    }

    /// The preferred area covers exactly this room but its channel IDs are
    /// unstreamable. Its membership still proves it is the same room, so room
    /// safety is unaffected and a usable equivalent is the right answer.
    func testAnUnusablePreferredAreaFallsBackToItsUsableEquivalent() {
        let broken = EntertainmentConfig(id: "broken", name: "Bedroom", channels: [
            channel(300, ent: ["E1"]), channel(1, ent: ["E2"]),
        ])
        let working = config("working", "Bedroom", ent: ["E1", "E2"])
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [broken, working],
                            entertainmentToLightMap: straightMap(2),
                            preferredConfigID: "broken")?.id,
            "working")
    }

    /// A preferred area with no channels at all proves nothing about which room
    /// it belongs to, so it is treated like an ID that names nothing rather than
    /// like a known equivalent.
    func testAPreferredAreaWithNoDerivableMembershipIsRejected() {
        let empty = EntertainmentConfig(id: "empty", name: "Bedroom", channels: [])
        let working = config("working", "Bedroom", ent: ["E1", "E2"])
        XCTAssertNil(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: [empty, working],
                            entertainmentToLightMap: straightMap(2),
                            preferredConfigID: "empty"))
    }

    // ── Two rooms, one bridge ─────────────────────────────────

    func testTwoRoomsOnOneBridgeEachGetTheirOwnArea() {
        let roomA = config("area-a", "Room A", ent: ["E1", "E2"])
        let roomB = config("area-b", "Room B", ent: ["E3", "E4"])
        let configs = [roomA, roomB]
        let membership = straightMap(4)

        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: configs,
                            entertainmentToLightMap: membership)?.id, "area-a")
        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L3", "L4"], configs: configs,
                            entertainmentToLightMap: membership)?.id, "area-b")
    }

    // ── Positions come from the same join ─────────────────────

    func testLightPositionsResolveThroughTheSameMapAsSelection() {
        let area = EntertainmentConfig(id: "area", name: "Bedroom", channels: [
            EntertainmentChannel(id: 0, lightServiceIDs: ["E1"], position: (x: -1, y: 0, z: 0.5)),
            EntertainmentChannel(id: 1, lightServiceIDs: ["E2"], position: (x: 1, y: 0, z: -0.5)),
        ])
        let positions = Selector.lightPositions(for: area, entertainmentToLightMap: straightMap(2))
        XCTAssertEqual(Set(positions.keys), ["L1", "L2"], "keyed by LIGHT id, not entertainment id")
        XCTAssertEqual(positions["L1"]?.x ?? 0, -1, accuracy: 0.0001)
        XCTAssertEqual(positions["L2"]?.z ?? 0, -0.5, accuracy: 0.0001)
    }

    // ─────────────────────────────────────────────────────────
    // MARK: - Exact target decision (hardware convergence slice A)
    // ─────────────────────────────────────────────────────────
    //
    // The defect these guard: on Brian's bridge one area spans
    // bedroom+bathroom and another spans bedroom+hallway. `select` correctly
    // refuses to guess for hallway and bathroom — and the UI reported that
    // refusal as "There's no compatible Entertainment Area for that room",
    // which is simply false. There are two. Only the user knows which.

    /// HC-01
    func testASingleExactCandidateAutoSelects() {
        let decision = Selector.decide(
            roomLightIDs: ["L1", "L2"],
            configs: [config("area-a", "Bedroom", ent: ["E1", "E2"])],
            entertainmentToLightMap: straightMap(2))

        guard case .exact(let picked) = decision else {
            return XCTFail("one safe area that exactly matches the room needs no question; got \(decision)")
        }
        XCTAssertEqual(picked.id, "area-a")
    }

    /// HC-02 — Brian's actual bridge, from the hallway's point of view.
    func testTwoOverlappingAreasRequireAChoiceInsteadOfReportingNone() {
        // bedroom+bathroom and bedroom+hallway; the request is the HALLWAY.
        let configs = [
            config("area-bb", "Bedroom + Bathroom", ent: ["E1", "E2"]),
            config("area-bh", "Bedroom + Hallway", ent: ["E1", "E3"]),
        ]
        let membership = straightMap(3)

        XCTAssertNil(
            Selector.select(roomLightIDs: ["L3"], configs: configs,
                            entertainmentToLightMap: membership),
            "precondition: the safe selector refuses to guess — that part was always right")

        guard case .choiceRequired(let options) = Selector.decide(
            roomLightIDs: ["L3"], configs: configs, entertainmentToLightMap: membership)
        else {
            return XCTFail("the hallway IS reachable — by one of two areas — so this is a question, not a refusal")
        }
        XCTAssertEqual(options.map(\.config.id), ["area-bh"],
            "only areas that actually touch the hallway are offered")
        XCTAssertEqual(options.first?.extraLightIDs, ["L1"],
            "and the bedroom light it drags along must be disclosed")
        XCTAssertTrue(options.first?.expandsScope ?? false)
    }

    /// HC-03 — the bedroom, which BOTH areas serve.
    func testARoomServedByTwoDifferentAreasAsksWhichOne() {
        let configs = [
            config("area-bb", "Bedroom + Bathroom", ent: ["E1", "E2"]),
            config("area-bh", "Bedroom + Hallway", ent: ["E1", "E3"]),
        ]
        guard case .choiceRequired(let options) = Selector.decide(
            roomLightIDs: ["L1"], configs: configs, entertainmentToLightMap: straightMap(3))
        else { return XCTFail("two areas cover the bedroom; picking one silently is the defect") }

        XCTAssertEqual(options.map(\.config.id), ["area-bb", "area-bh"],
            "both are offered, each under its own name")
        XCTAssertTrue(options.allSatisfy(\.expandsScope),
            "each reaches a room the user did not ask about, and each must say so")
    }

    /// HC-04 — the no-collapse rule.
    ///
    /// Two areas over the SAME lights are still two areas. "TV" and "Movie
    /// Night" are not interchangeable because their light sets match, and
    /// `min(by: id)` picking one of them is a hidden choice — indistinguishable
    /// from a wrong one.
    func testTwoAreasOverIdenticalLightsAreBothOfferedAndNeitherIsCollapsed() {
        let configs = [
            config("area-tv", "TV", ent: ["E1", "E2"]),
            config("area-movie", "Movie Night", ent: ["E1", "E2"]),
        ]
        let membership = straightMap(2)

        XCTAssertEqual(
            Selector.select(roomLightIDs: ["L1", "L2"], configs: configs,
                            entertainmentToLightMap: membership)?.id, "area-movie",
            "precondition: the legacy selector DOES collapse these to the lowest id")

        guard case .choiceRequired(let options) = Selector.decide(
            roomLightIDs: ["L1", "L2"], configs: configs, entertainmentToLightMap: membership)
        else { return XCTFail("identical light sets must not license a silent pick") }

        XCTAssertEqual(options.map(\.config.id), ["area-movie", "area-tv"])
        XCTAssertEqual(options.map(\.config.name), ["Movie Night", "TV"],
            "each candidate keeps its own exact id and its own name")
    }

    /// HC-05 — ordering is display, never selection.
    func testReorderingTheSameCandidatesProducesTheIdenticalDecision() {
        let a = config("area-bb", "Bedroom + Bathroom", ent: ["E1", "E2"])
        let b = config("area-bh", "Bedroom + Hallway", ent: ["E1", "E3"])
        let membership = straightMap(3)

        let forward = Selector.decide(roomLightIDs: ["L1"], configs: [a, b],
                                      entertainmentToLightMap: membership)
        let reversed = Selector.decide(roomLightIDs: ["L1"], configs: [b, a],
                                       entertainmentToLightMap: membership)

        XCTAssertEqual(forward, reversed,
            "array order may not change the answer OR the order it is presented in")
    }

    /// HC-06 — a single area reaching outside the room is still a question.
    func testALoneAreaThatReachesOutsideTheRoomIsOfferedWithItsScopeStated() {
        guard case .choiceRequired(let options) = Selector.decide(
            roomLightIDs: ["L3"],
            configs: [config("area-bh", "Bedroom + Hallway", ent: ["E1", "E3"])],
            entertainmentToLightMap: straightMap(3))
        else { return XCTFail("Hue streams whole configurations — this IS the hallway's only option") }

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].lightIDs, ["L3"], "what it lights in the room asked for")
        XCTAssertEqual(options[0].extraLightIDs, ["L1"], "and what it lights outside it")
    }

    /// HC-07
    func testAnAreaTouchingNoneOfTheRoomsLightsIsNeverOffered() {
        let decision = Selector.decide(
            roomLightIDs: ["L1"],
            configs: [config("area-far", "Kitchen", ent: ["E2", "E3"])],
            entertainmentToLightMap: straightMap(3))

        XCTAssertEqual(decision, .noCompatible,
            "another room's area is not a candidate, so it is never shown and never picked")
    }

    /// HC-08 — an unstreamable area cannot be offered.
    func testAnAreaWithoutUsableChannelIDsIsNotACandidate() {
        let broken = EntertainmentConfig(id: "area-broken", name: "Broken", channels: [
            channel(0, ent: ["E1"]), channel(0, ent: ["E2"]),   // duplicate channel ids
        ])
        XCTAssertEqual(
            Selector.decide(roomLightIDs: ["L1", "L2"], configs: [broken],
                            entertainmentToLightMap: straightMap(2)),
            .noCompatible,
            "offering an area that startup would then refuse is a promise we cannot keep")
    }

    /// HC-09 — an explicit selection is honoured only while it still fits.
    func testAnExplicitSelectionResolvesExactlyAndAStaleOneResolvesToNothing() {
        let configs = [
            config("area-bb", "Bedroom + Bathroom", ent: ["E1", "E2"]),
            config("area-bh", "Bedroom + Hallway", ent: ["E1", "E3"]),
        ]
        let membership = straightMap(3)

        guard case .exact(let chosen) = Selector.decide(
            roomLightIDs: ["L1"], configs: configs,
            entertainmentToLightMap: membership, preferredConfigID: "area-bh")
        else { return XCTFail("the user named an area that serves this room") }
        XCTAssertEqual(chosen.id, "area-bh", "and it is the one they named, not the lowest id")

        XCTAssertEqual(
            Selector.decide(roomLightIDs: ["L1"], configs: configs,
                            entertainmentToLightMap: membership,
                            preferredConfigID: "area-deleted"),
            .noCompatible,
            "a selection that no longer names a candidate resolves to nothing — never to a substitute")
    }

    /// HC-11 — the save vocabulary keeps its outcomes distinct, and none of
    /// them leaks protocol words.
    ///
    /// The device pass found effects running after a force-close with no
    /// recovered row and no Stop. The app knew which transport it had used; it
    /// had no words for it. These are those words. Round 3 added four more:
    /// no-lights vs couldn't-check (an empty room and an unreadable bridge
    /// are different problems), the save-flavoured replacement refusal, and
    /// the overlapping-save refusal.
    func testBridgeSaveCopyKeepsItsFourOutcomesDistinctAndJargonFree() {
        let outcomes = [
            BridgeSaveCopy.savedAndRunning,
            BridgeSaveCopy.savedNotConfirmedRunning,
            BridgeSaveCopy.saveFailedNothingRecorded,
            BridgeSaveCopy.saveFailedResourcesRemain,
            BridgeSaveCopy.savedAsSceneNotStoppable,
            BridgeSaveCopy.saveFailedNoLights,
            BridgeSaveCopy.saveFailedLightsUnresolved,
            BridgeSaveCopy.saveFailedReplacementBlocked,
            BridgeSaveCopy.saveAlreadyInProgress,
            BridgeSaveCopy.partialCleanupRecoverable,
            BridgeSaveCopy.partialCleanupNotDurable,
            BridgeSaveCopy.previousLookRemovedSaveFailed,
            BridgeSaveCopy.savedNotConfirmedPreviousLookRemoved,
            // Round 4f: the neutral superseded-state variants — playback
            // changed while the save completed, so neither "nothing is
            // playing" nor "a look is playing" may be claimed.
            BridgeSaveCopy.previousLookRemovedSaveFailedPlaybackChanged,
            BridgeSaveCopy.savedNotConfirmedPreviousLookRemovedPlaybackChanged,
        ]
        XCTAssertEqual(Set(outcomes).count, outcomes.count,
            "outcomes that oblige the user to do different things may not share a sentence")

        // The one deliberate alias: "saved and running" IS the bridge-run
        // sentence. One meaning, one literal, so the two surfaces cannot drift.
        XCTAssertEqual(BridgeSaveCopy.savedAndRunning, TransportVocabulary.bridgeRunTruth,
            "the save result and the transport badge must say the same thing")

        let all = outcomes + [BridgeSaveCopy.noLocalPreset,
                              TransportVocabulary.appDrivenTruth]

        let jargon = ["manifest", "configuration ID", "entertainment_configuration",
                      "REST", "DTLS", "resourcelink", "sensor", "UUID", "registry"]
        for sentence in all {
            for word in jargon {
                XCTAssertFalse(sentence.lowercased().contains(word.lowercased()),
                    "'\(word)' leaked into user-facing copy: \(sentence)")
            }
        }
    }

    /// HC-12 — the two transports are stated as opposites, and the one thing
    /// the user most needs is in both: does closing the app stop the lights?
    func testTheTwoTransportSentencesAnswerTheForceCloseQuestion() {
        XCTAssertTrue(TransportVocabulary.appDrivenTruth.lowercased().contains("closes"),
            "app-driven must say the lights stop when the app closes: \(TransportVocabulary.appDrivenTruth)")
        XCTAssertTrue(TransportVocabulary.bridgeRunTruth.lowercased().contains("bridge"),
            "bridge-run must name the bridge: \(TransportVocabulary.bridgeRunTruth)")
        XCTAssertNotEqual(TransportVocabulary.appDrivenTruth, TransportVocabulary.bridgeRunTruth)
    }

    /// HC-13 — a Hue dynamic scene is bridge-run but NOT ChromaGlow-stoppable.
    /// Promising a Stop we cannot deliver sends the user hunting for a control
    /// that does not exist.
    func testTheDynamicSceneSentenceNeverPromisesAChromaGlowStop() {
        let copy = BridgeSaveCopy.savedAsSceneNotStoppable
        XCTAssertTrue(copy.contains("Scenes"),
            "it must say where the scene actually lives: \(copy)")
        XCTAssertNotEqual(copy, BridgeSaveCopy.savedAndRunning,
            "a scene and a manifest-backed look are not the same promise")
    }

    /// HC-10 — a selection may not buy its way into another room.
    func testAnExplicitSelectionCannotNameAnAreaThatDoesNotTouchThisRoom() {
        XCTAssertEqual(
            Selector.decide(
                roomLightIDs: ["L1"],
                configs: [config("area-a", "Bedroom", ent: ["E1"]),
                          config("area-far", "Kitchen", ent: ["E2", "E3"])],
                entertainmentToLightMap: straightMap(3),
                preferredConfigID: "area-far"),
            .noCompatible,
            "an id the user once picked cannot redirect this room's stream into the kitchen")
    }
}
