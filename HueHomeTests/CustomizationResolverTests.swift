//
//  CustomizationResolverTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 1 capability/availability proofs.
//
//  The resolver is pure and total, so the whole of spec §17's availability
//  matrix is a unit test rather than a device checklist. Nothing here touches
//  the network, a clock, or the orchestrator.
//

import XCTest
@testable import HueHome

@MainActor
final class CustomizationResolverTests: XCTestCase {

    // ── Builders ────────────────────────────────────────────────

    private func identity(card: String = "party",
                          engine: String = "party",
                          generation: UInt64 = 1) -> RunningLookIdentity {
        RunningLookIdentity(bridgeID: "bridge-A",
                            groupID: "room-1",
                            kind: .room,
                            cardID: card,
                            execution: .appDriven(engineKey: engine),
                            generation: CustomizationGeneration(generation))
    }

    /// A fully capable, running, streaming target.
    private func richTarget(cardID: String = "party",
                            transport: CustomizationTransport = .entertainment,
                            running: Bool = true,
                            lights: Int = 4) -> CustomizationTargetSnapshot {
        CustomizationTargetSnapshot(
            identity: identity(card: cardID, engine: cardID),
            totalLights: lights,
            reachableLights: lights,
            dimming: .all(total: lights),
            color: .all(total: lights),
            colorTemperature: .all(total: lights),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .all(total: lights),
            effectsV2: .all(total: lights),
            verifiedEffectParameters: ["candle": ["brightness", "speed"]],
            entertainmentAvailable: .known,
            transport: transport,
            running: running)
    }

    private func control(_ paramID: String,
                         card: String = "party",
                         requirement: CapabilityRequirement,
                         live: CustomizationMutationBehavior = .immediate,
                         cards: Set<String> = []) -> CustomizationControlDescriptor {
        CustomizationControlDescriptor(
            id: CustomizationControlID(cardID: card, paramID: paramID),
            requirement: requirement,
            liveBehavior: live,
            appliesToExecution: cards)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - The five availability states  (spec §17)
    // ──────────────────────────────────────────────────────────

    func testFullyCapableRunningTargetResolvesActive() {
        let resolution = CustomizationResolver.resolve(
            control: control("color", requirement: .color),
            on: richTarget())

        XCTAssertEqual(resolution.availability, .active)
        XCTAssertEqual(resolution.behavior, .immediate)
    }

    func testCapableButNotRunningResolvesStagedWithAStartRemediation() {
        let resolution = CustomizationResolver.resolve(
            control: control("color", requirement: .color),
            on: richTarget(running: false, lights: 4))

        XCTAssertEqual(resolution.availability,
                       .staged(reason: .notRunning, remediation: .startTheLook))
    }

    func testNoColorCapableLightsResolvesUnavailable() {
        var target = richTarget()
        target = CustomizationTargetSnapshot(
            identity: target.identity, totalLights: 3, reachableLights: 3,
            dimming: .all(total: 3),
            color: .none(total: 3),
            colorTemperature: .all(total: 3),
            mirekRange: MirekRange(minMirek: 200, maxMirek: 400),
            gradient: .none(total: 3), effectsV2: .all(total: 3),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("color", requirement: .color), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .noColorCapableLights,
                                    remediation: .addCapableLights))
    }

    /// Mixed room: some lights render colour, some do not. The control stays
    /// usable and states its coverage rather than pretending to full reach.
    func testMixedCapabilityTargetResolvesPartialWithCoverage() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 5, reachableLights: 5,
            dimming: .all(total: 5),
            color: CapabilityCoverage(supported: 2, total: 5, evidence: .known),
            colorTemperature: .all(total: 5),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .none(total: 5), effectsV2: .all(total: 5),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("color", requirement: .color), on: target)

        XCTAssertEqual(resolution.availability,
                       .partial(supported: 2, total: 5, reason: .partialHardwareCoverage))
    }

    func testControlOnTheWrongCardIsHidden() {
        let resolution = CustomizationResolver.resolve(
            control: control("duty_cycle", card: "strobe",
                             requirement: .none, cards: ["strobe"]),
            on: richTarget(cardID: "party"))

        XCTAssertEqual(resolution.availability, .hidden)
        XCTAssertFalse(resolution.availability.rendersControl)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Unknown is NOT unsupported  (spec §17, audit §5)
    // ──────────────────────────────────────────────────────────

    func testUnknownCapabilityResolvesUnavailableWithRetryNotSilentUnsupported() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3),
            color: .unknown(total: 3),
            colorTemperature: .unknown(total: 3),
            gradient: .unknown(total: 3), effectsV2: .unknown(total: 3),
            entertainmentAvailable: .unknown, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("color", requirement: .color), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .capabilityUnknown,
                                    remediation: .retryCapabilityFetch))
    }

    func testUnreadableCapabilityIsDistinctFromUnsupported() {
        func target(_ evidence: CapabilityEvidence) -> CustomizationTargetSnapshot {
            CustomizationTargetSnapshot(
                identity: identity(), totalLights: 2,
                dimming: .all(total: 2),
                color: CapabilityCoverage(supported: 0, total: 2, evidence: evidence),
                colorTemperature: .all(total: 2),
                gradient: .none(total: 2), effectsV2: .none(total: 2),
                entertainmentAvailable: .known, transport: .entertainment, running: true)
        }

        let unreadable = CustomizationResolver.resolve(
            control: control("color", requirement: .color), on: target(.unreadable))
        let unsupported = CustomizationResolver.resolve(
            control: control("color", requirement: .color), on: target(.unsupported))

        XCTAssertEqual(unreadable.availability,
                       .unavailable(reason: .capabilityUnknown, remediation: .retryCapabilityFetch))
        XCTAssertEqual(unsupported.availability,
                       .unavailable(reason: .noColorCapableLights, remediation: .addCapableLights))
        XCTAssertNotEqual(unreadable.availability, unsupported.availability)
    }

    /// UNKNOWN `.effectsV2` must not borrow the UNSUPPORTED answer.
    ///
    /// The old mapping sent both outcomes to `.effectsV2Unavailable`, whose
    /// board copy is "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING" — a
    /// hardware refusal asserted on evidence we never read. On a cold snapshot
    /// that made the Speed knob contradict the three controls beside it, which
    /// correctly said we were still checking. Unknown must never read as a
    /// refusal; `.effectsV2Unavailable` is now reachable from `unsupported`
    /// alone.
    func testUnknownEffectsV2StaysInTheUnknownFamily() {
        func target(_ evidence: CapabilityEvidence) -> CustomizationTargetSnapshot {
            CustomizationTargetSnapshot(
                identity: identity(), totalLights: 3,
                dimming: .all(total: 3), color: .all(total: 3),
                colorTemperature: .all(total: 3), gradient: .all(total: 3),
                effectsV2: CapabilityCoverage(supported: 0, total: 3, evidence: evidence),
                entertainmentAvailable: .known, transport: .bridgeEffectV2, running: true)
        }

        for evidence in [CapabilityEvidence.unknown, .unreadable] {
            let resolution = CustomizationResolver.resolve(
                control: control("speed", requirement: .effectsV2), on: target(evidence))
            guard case .unavailable(let reason, let remediation) = resolution.availability else {
                return XCTFail("expected unavailable for \(evidence), got \(resolution.availability)")
            }
            XCTAssertTrue(reason == .capabilityUnknown || reason == .capabilityUnreadable,
                          "\(evidence) must stay unknown, got \(reason)")
            XCTAssertNotEqual(reason, .effectsV2Unavailable,
                              "unknown must never read as the hardware refusal")
            XCTAssertEqual(remediation, .retryCapabilityFetch,
                           "an unknown answer offers a retry; a refusal does not")
        }
    }

    /// …and the refusal itself is untouched: a bridge that ANSWERED and said
    /// no still gets the reason whose copy names the hardware fact.
    func testUnsupportedEffectsV2KeepsTheRefusalReason() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3), color: .all(total: 3),
            colorTemperature: .all(total: 3), gradient: .all(total: 3),
            effectsV2: .none(total: 3),
            entertainmentAvailable: .known, transport: .legacy, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("speed", requirement: .effectsV2), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .effectsV2Unavailable,
                                    remediation: .addCapableLights))
    }

    /// An effect/parameter pair that was never verified must never be exposed
    /// as supported — audit §7's "never guess".
    ///
    /// The reason stays `.effectParameterUnverified` (the audit's own word),
    /// but the REMEDIATION is what separates the two flavours for the board:
    /// unknown offers a retry and renders as checking, unsupported offers
    /// nothing and renders as a plain "not available". Unknown must never
    /// read as a refusal.
    func testUnverifiedEffectParameterIsUnknownNotSupported() {
        let resolution = CustomizationResolver.resolve(
            control: control("tint", requirement: .effectParameter(effect: "prism",
                                                                  parameter: "tint")),
            on: richTarget())

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .effectParameterUnverified,
                                    remediation: .retryCapabilityFetch))
    }

    func testVerifiedEffectParameterIsActive() {
        let resolution = CustomizationResolver.resolve(
            control: control("speed", requirement: .effectParameter(effect: "candle",
                                                                    parameter: "speed")),
            on: richTarget())

        XCTAssertEqual(resolution.availability, .active)
    }

    func testEffectParameterVerifiedForAnotherParameterIsUnsupported() {
        let resolution = CustomizationResolver.resolve(
            control: control("warmth", requirement: .effectParameter(effect: "candle",
                                                                     parameter: "warmth")),
            on: richTarget())

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .effectParameterUnverified, remediation: nil))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Transport  (audit §17 — replacing `entOnly`)
    // ──────────────────────────────────────────────────────────

    /// The three `entOnly` params today. Running but on the wrong transport is
    /// STAGED — the value is real and applies the moment streaming arrives —
    /// not "unavailable", and certainly not silently active.
    func testStreamingOnlyControlIsStagedWhileRunningOnRoomREST() {
        let resolution = CustomizationResolver.resolve(
            control: control("duty_cycle", requirement: .transport(.entertainment)),
            on: richTarget(transport: .roomREST))

        XCTAssertEqual(resolution.availability,
                       .staged(reason: .requiresEntertainment, remediation: .enableStreaming))
        XCTAssertEqual(resolution.behavior, .staged)
    }

    func testStreamingOnlyControlIsActiveWhileStreaming() {
        let resolution = CustomizationResolver.resolve(
            control: control("duty_cycle", requirement: .transport(.entertainment)),
            on: richTarget(transport: .entertainment))

        XCTAssertEqual(resolution.availability, .active)
    }

    func testTransportRequirementIsUnknownWhileNothingRuns() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 2,
            dimming: .all(total: 2), color: .all(total: 2),
            colorTemperature: .all(total: 2), gradient: .none(total: 2),
            effectsV2: .all(total: 2),
            entertainmentAvailable: .known, transport: .none, running: false)

        let resolution = CustomizationResolver.resolve(
            control: control("duty_cycle", requirement: .transport(.entertainment)),
            on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .capabilityUnknown,
                                    remediation: .retryCapabilityFetch))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Combinators
    // ──────────────────────────────────────────────────────────

    func testAllRequirementTakesTheNarrowestCoverage() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 6,
            dimming: CapabilityCoverage(supported: 5, total: 6, evidence: .known),
            color: CapabilityCoverage(supported: 2, total: 6, evidence: .known),
            colorTemperature: .all(total: 6),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .none(total: 6), effectsV2: .all(total: 6),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .all([.dimming, .color])), on: target)

        XCTAssertEqual(resolution.availability,
                       .partial(supported: 2, total: 6, reason: .partialHardwareCoverage))
    }

    func testAllRequirementFailsFastOnAHardNo() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3), color: .none(total: 3),
            colorTemperature: .all(total: 3), gradient: .none(total: 3),
            effectsV2: .all(total: 3),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .all([.dimming, .color])), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .noColorCapableLights, remediation: .addCapableLights))
    }

    /// Unknown outranks partial inside `.all` — we must not advertise coverage
    /// figures for a capability we could not read.
    func testUnknownOutranksPartialInsideAll() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 4,
            dimming: CapabilityCoverage(supported: 2, total: 4, evidence: .known),
            color: .unknown(total: 4),
            colorTemperature: .all(total: 4), gradient: .none(total: 4),
            effectsV2: .all(total: 4),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .all([.dimming, .color])), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .capabilityUnknown, remediation: .retryCapabilityFetch))
    }

    /// A CT-only room: colour is unsupported, CT is fully supported WITH a
    /// readable range. One satisfied branch carries `.any`.
    ///
    /// The `mirekRange` here is load-bearing, not decoration — omitting it makes
    /// `.colorTemperature` resolve `.unknown` (see
    /// `testCTCapableButRangelessTargetIsUnknownNotActive`) and there is then no
    /// satisfied branch at all.
    func testAnyRequirementSucceedsOnOneSatisfiedBranch() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3), color: .none(total: 3),
            colorTemperature: .all(total: 3),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .none(total: 3),
            effectsV2: .none(total: 3),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .any([.color, .colorTemperature])), on: target)

        XCTAssertEqual(resolution.availability, .active)
    }

    /// The companion case: no branch is satisfied and one is unknown, so the
    /// whole `.any` is unknown rather than a flat "unsupported". This is the
    /// shape the original version of the test above accidentally built, and it
    /// is worth locking deliberately.
    func testAnyRequirementIsUnknownWhenNoBranchIsSatisfiedAndOneIsUnreadable() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3), color: .none(total: 3),
            colorTemperature: .all(total: 3),
            mirekRange: nil,                      // CT claimed, range unreadable
            gradient: .none(total: 3),
            effectsV2: .none(total: 3),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .any([.color, .colorTemperature])), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .capabilityUnknown,
                                    remediation: .retryCapabilityFetch))
    }

    /// And when every branch is a hard no, `.any` is unsupported — not unknown.
    func testAnyRequirementIsUnsupportedWhenEveryBranchIsAHardNo() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 3,
            dimming: .all(total: 3), color: .none(total: 3),
            colorTemperature: .none(total: 3),
            gradient: .none(total: 3), effectsV2: .none(total: 3),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("x", requirement: .any([.color, .colorTemperature])), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .notApplicableToThisLook, remediation: nil))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - CT honesty  (audit §19)
    // ──────────────────────────────────────────────────────────

    func testCTCapableButRangelessTargetIsUnknownNotActive() {
        let target = CustomizationTargetSnapshot(
            identity: identity(), totalLights: 2,
            dimming: .all(total: 2), color: .all(total: 2),
            colorTemperature: .all(total: 2),
            mirekRange: nil,                     // claims CT, no readable range
            gradient: .none(total: 2), effectsV2: .all(total: 2),
            entertainmentAvailable: .known, transport: .entertainment, running: true)

        let resolution = CustomizationResolver.resolve(
            control: control("warmth", requirement: .colorTemperature), on: target)

        XCTAssertEqual(resolution.availability,
                       .unavailable(reason: .capabilityUnknown, remediation: .retryCapabilityFetch))
    }

    func testMirekRangesIntersectAndReportNoOverlapHonestly() {
        let warm = MirekRange(minMirek: 300, maxMirek: 500)!
        let cool = MirekRange(minMirek: 153, maxMirek: 250)!
        let wide = MirekRange(minMirek: 200, maxMirek: 454)!

        XCTAssertNil(warm.intersected(with: cool), "no overlap must not silently clamp")
        XCTAssertEqual(warm.intersected(with: wide),
                       MirekRange(minMirek: 300, maxMirek: 454))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Determinism  (audit §23)
    // ──────────────────────────────────────────────────────────

    func testResolveAllIsDeterministicAndStablySorted() {
        let controls = [
            control("speed",  requirement: .none),
            control("color",  requirement: .color),
            control("warmth", requirement: .colorTemperature),
        ]
        let target = richTarget()

        let first  = CustomizationResolver.resolveAll(controls: controls, on: target)
        let second = CustomizationResolver.resolveAll(controls: controls.reversed(), on: target)

        XCTAssertEqual(first, second, "order of input must not change output")
        XCTAssertEqual(first.map(\.control.description),
                       ["party.color", "party.speed", "party.warmth"])
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Control identity  (audit §9 — the sentinel trap)
    // ──────────────────────────────────────────────────────────

    /// The dead sentinel `ambient.color` and the LIVE `thunderstorm.ambient_color`
    /// must never compare equal. A substring check conflates them; whole-ID
    /// comparison cannot.
    func testDeadAmbientColorSentinelIsNotTheLiveThunderstormAmbientColor() {
        let deadSentinel = CustomizationControlID(cardID: "ambient", paramID: "color")
        let liveControl  = CustomizationControlID(cardID: "thunderstorm", paramID: "ambient_color")

        XCTAssertNotEqual(deadSentinel, liveControl)
        XCTAssertEqual(deadSentinel.description, "ambient.color")
        XCTAssertEqual(liveControl.description, "thunderstorm.ambient_color")

        // The trap itself, stated as an assertion: the naive check passes when
        // it should not, which is why the codebase must compare whole IDs.
        XCTAssertTrue(liveControl.description.contains("ambient"),
                      "documents why substring matching on these ids is unsafe")
    }

    func testControlIDsAreValueTypesUsableAsDictionaryKeys() {
        var seen: [CustomizationControlID: Int] = [:]
        seen[CustomizationControlID(cardID: "party", paramID: "speed")] = 1
        seen[CustomizationControlID(cardID: "strobe", paramID: "speed")] = 2

        XCTAssertEqual(seen.count, 2, "same param id on two cards are two controls")
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Catalog facts the foundation depends on
// ──────────────────────────────────────────────────────────────

/// These assert against the REAL catalog, so the Slice 1 foundation cannot
/// drift away from the shipping cards while nobody is looking.
@MainActor
final class CustomizationCatalogFactsTests: XCTestCase {

    private var vm: StudioViewModel!

    override func setUp() async throws {
        vm = StudioViewModel()
    }

    /// Slice 2 will render Beat inline. It may only do so for engines that
    /// genuinely consume the shared beat source — spec §21. No Live card
    /// declares a Beat param today, and this locks that fact so a Beat control
    /// cannot be added to the catalog without someone revisiting this test and
    /// the consumption proof behind it.
    func testNoLiveCardDeclaresABeatParamYet() {
        for card in vm.liveModeCards {
            for param in card.params {
                XCTAssertFalse(param.id.hasPrefix("beat"),
                               "\(card.id).\(param.id) declares Beat — prove engine consumption first (spec §21)")
            }
        }
    }

    /// Every Live and Effect control maps to a unique `CustomizationControlID`.
    /// Slice 1's whole descriptor model assumes this.
    func testEveryCatalogControlHasAUniqueSemanticID() {
        var seen = Set<CustomizationControlID>()
        for card in vm.effectCards + vm.liveModeCards {
            for param in card.params {
                let id = CustomizationControlID(cardID: card.id, paramID: param.id)
                XCTAssertTrue(seen.insert(id).inserted, "duplicate control id \(id)")
            }
        }
        XCTAssertFalse(seen.isEmpty)
    }

    /// The live `thunderstorm.ambient_color` really is in the shipping catalog.
    /// If this ever fails, the control was removed — and audit §9's warning
    /// about the dead-sentinel substring trap has a real casualty.
    func testThunderstormAmbientColorIsStillAShippingControl() {
        let storm = vm.liveModeCards.first { $0.id == "thunderstorm" }
        XCTAssertNotNil(storm)
        XCTAssertTrue(storm?.params.contains { $0.id == "ambient_color" } ?? false,
                      "thunderstorm.ambient_color has a live consumer (UnifiedOrchestrator ~8219)")
    }

    /// The Ambient card must NOT have a colour control — the dead sentinel.
    func testAmbientCardHasNoColorControl() {
        let ambient = vm.liveModeCards.first { $0.id == "ambient" }
        XCTAssertNotNil(ambient)
        XCTAssertFalse(ambient?.params.contains { $0.id == "color" } ?? true,
                       "ambient.color is dead (audit §9)")
    }

    /// `entOnly` is set on exactly the three params the audit recorded. When
    /// Slice 2 migrates these to `CapabilityRequirement.transport(.entertainment)`,
    /// this test is the inventory that says the migration is complete.
    func testEntOnlyInventoryMatchesTheAuditedSeven() {
        // Slice 2 deliberately EXPANDED this inventory from the audited three:
        // the engine-loop reverse-audit (audit §2C) proved four more params
        // are read only by the Entertainment loops and silently ignored by
        // the REST fallbacks — party.speed (REST runs a fixed 1 s cadence),
        // party.min_brightness (REST sends peak brightness only), and
        // thunderstorm.flash_length / afterglow (frame-level flash shaping
        // that only the 50 fps stream can express). Flagging them is the
        // transport honesty spec §17 demands; hiding the flag was the defect.
        var flagged: [String] = []
        for card in vm.effectCards + vm.liveModeCards {
            for param in card.params where param.entOnly {
                flagged.append("\(card.id).\(param.id)")
            }
        }
        XCTAssertEqual(flagged.sorted(),
                       ["party.min_brightness", "party.speed",
                        "strobe.duty_cycle", "strobe.flash_color", "strobe.speed",
                        "thunderstorm.afterglow", "thunderstorm.flash_length"])

        // The migration itself. `entOnly` is now catalog metadata only: the
        // DECISION is made once, by `StudioBoardAvailability` translating the
        // flag into `.transport(.entertainment)` for the resolver. Every
        // flagged param must carry the requirement, and no unflagged one may.
        var migrated: [String] = []
        for card in vm.effectCards + vm.liveModeCards {
            for param in card.params {
                guard let descriptor = StudioBoardAvailability.descriptor(card: card,
                                                                          param: param) else {
                    XCTAssertFalse(param.entOnly,
                                   "\(card.id).\(param.id) is entOnly but bypasses the funnel")
                    continue
                }
                if Self.requiresEntertainmentTransport(descriptor.requirement) {
                    migrated.append("\(card.id).\(param.id)")
                }
            }
        }
        XCTAssertEqual(migrated.sorted(), flagged.sorted(),
                       "entOnly → .transport(.entertainment) migration is incomplete")
    }

    /// Does this requirement tree demand the Entertainment transport anywhere?
    private static func requiresEntertainmentTransport(
        _ requirement: CapabilityRequirement
    ) -> Bool {
        switch requirement {
        case .transport(let transport):
            return transport == .entertainment
        case .all(let parts), .any(let parts):
            return parts.contains { requiresEntertainmentTransport($0) }
        default:
            return false
        }
    }
}
