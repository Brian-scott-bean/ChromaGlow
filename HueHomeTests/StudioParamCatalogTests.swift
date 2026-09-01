// StudioParamCatalogTests.swift
// HueHome Pro — Unit Tests
//
// Adjustment-settings revamp: the card catalogs must stay honest. Every
// declared param is read by something (sendParam, an engine loop, or the
// v2 apply path), essential density stays scannable, and params the audit
// removed as dead never come back silently.

import XCTest
@testable import HueHome

@MainActor
final class StudioParamCatalogTests: XCTestCase {

    private var vm: StudioViewModel!

    override func setUp() async throws {
        vm = StudioViewModel()
    }

    private var allCards: [StudioCard] { vm.effectCards + vm.liveModeCards }

    // ── Build-47 device finding 2 — "+ Create" reports what it actually did ──
    //
    // The outcome is measured against the room captured AT THE TAP. Inferring it
    // from `currentRoomEffect` would be wrong twice: that follows `selectedRoom`,
    // so a mid-await scrub reports on a room the user was not creating in, and it
    // cannot tell a fresh start from the starter card that was already running.

    /// Exact identity for an injected fixture row (Slice 2 wiring).
    private func testIdentity(room: RoomDisplayItem, card: StudioCard) -> RunningLookIdentity {
        let execution: CustomizationExecution
        switch card.strategy {
        case .bridgeNative(let effect): execution = .bridgeNative(effect: effect)
        case .appDriven(let key):       execution = .appDriven(engineKey: key)
        case .composition(let pid):     execution = .composition(presetID: pid)
        }
        return RunningLookIdentity(
            bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
            cardID: card.id, execution: execution,
            generation: vm.generationCounter.bump(.cardReplaced))
    }

    private func room(_ id: String, bridge: String = "bridge-a") -> RoomDisplayItem {
        RoomDisplayItem(
            id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: nil, lightCount: 2, bridgeID: bridge, childResourceRefs: [])
    }

    /// No room means nothing was created — `apply` refuses and the editor stays shut.
    func testCreateWithNoRoomSelectedReportsNoCreation() async {
        let before = vm.runningEffects
        let outcome = await vm.createStarterComposition(in: nil)

        XCTAssertFalse(outcome.createdNewComposition, "a refused creation must not open the editor")
        XCTAssertNil(outcome.target)
        XCTAssertFalse(outcome.draftReady)
        XCTAssertFalse(outcome.applied)
        XCTAssertEqual(before.count, vm.runningEffects.count, "…and must not touch playback")
    }

    /// Tapping "+ Create" while the starter card is ALREADY running in that room
    /// starts nothing new. This is exactly what a `currentRoomEffect?.cardID ==
    /// card.id` check could not see — it would report success for a re-entry.
    func testCreateReportsNoCreationWhenTheStarterCardWasAlreadyRunning() async {
        let target = room("room-a")
        let card = vm.starterCompositionCard()
        vm.selectedRoom = target
        vm.runningEffects[StudioSelectionKey(room: target)] = RunningEffect(
            cardID: card.id, card: card, room: target, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: testIdentity(room: target, card: card))

        let outcome = await vm.createStarterComposition(in: target)

        XCTAssertTrue(outcome.wasAlreadyRunning, "the starter card was already running here")
        XCTAssertFalse(outcome.createdNewComposition,
            "a re-entry on an already-running card is not a creation and must not open the editor")
    }

    /// The outcome names the room passed in, not whatever the wheel settled on
    /// while the creation was in flight.
    func testCreationOutcomeCarriesTheTargetCapturedAtTheTap() async {
        let tapped = room("room-a")
        let scrolledTo = room("room-b")
        vm.selectedRoom = tapped

        let outcome = await vm.createStarterComposition(in: tapped)
        vm.selectedRoom = scrolledTo   // the user scrubbed during the await

        XCTAssertEqual(outcome.target, StudioSelectionKey(room: tapped))
        XCTAssertNotEqual(outcome.target, StudioSelectionKey(room: scrolledTo))
    }

    /// Room-exactness of the MEASUREMENT: `wasAlreadyRunning` is read off the
    /// captured room even when the live selection has moved elsewhere. A
    /// `currentRoomEffect` check would have read room-b here and reported false.
    func testCreationOutcomeIsMeasuredAgainstTheCapturedRoomNotTheLiveSelection() async {
        let tapped = room("room-a")
        let elsewhere = room("room-b")
        let card = vm.starterCompositionCard()
        vm.runningEffects[StudioSelectionKey(room: tapped)] = RunningEffect(
            cardID: card.id, card: card, room: tapped, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: testIdentity(room: tapped, card: card))
        vm.selectedRoom = elsewhere

        let outcome = await vm.createStarterComposition(in: tapped)

        XCTAssertTrue(outcome.wasAlreadyRunning,
            "the outcome must describe the captured room, not the live selection")
        XCTAssertEqual(outcome.target, StudioSelectionKey(room: tapped))
    }

    /// The async race, evaluated exactly as the "+ Create" call site does. Even a
    /// genuine creation must not open the editor once the user has scrubbed away —
    /// it would present a surface for a room they already left.
    func testScrubbingAwayDuringCreationDoesNotSatisfyTheOpenGuard() {
        let tapped = room("room-a")
        let outcome = StudioViewModel.NewCompositionCreation(
            target: StudioSelectionKey(room: tapped),
            draftReady: true, wasAlreadyRunning: false, applied: true)
        XCTAssertTrue(outcome.createdNewComposition, "fixture: this IS a real creation")

        vm.selectedRoom = tapped
        XCTAssertEqual(vm.selectedRoom.map(StudioSelectionKey.init), outcome.target,
            "still on the tapped room — the editor opens")

        vm.selectedRoom = room("room-b")
        XCTAssertNotEqual(vm.selectedRoom.map(StudioSelectionKey.init), outcome.target,
            "scrubbed away — the guard must fail even though creation succeeded")
    }

    // ── Density ───────────────────────────────────────────────

    /// The compact tray shows essential params inline — keep it scannable.
    func testEveryCardHasOneToThreeEssentialParams() {
        for card in allCards {
            let count = card.params.filter { $0.tier == .essential }.count
            XCTAssertTrue((1...3).contains(count),
                          "\(card.id) has \(count) essential params")
        }
    }

    func testParamIDsAreUniquePerCard() {
        for card in allCards {
            let ids = card.params.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(card.id) has duplicate param ids")
        }
    }

    // ── Dead params stay dead ─────────────────────────────────

    /// Audit (2026-07-09): these params were never read by any engine loop
    /// or send path. If one returns, it must come with a consumer.
    func testRemovedDeadParamsAreAbsent() {
        let dead: [(card: String, param: String)] = [
            ("thunderstorm", "brightness"),   // loops read frequency/flash_intensity/min_brightness only
            ("party", "saturation"),          // never read anywhere
            ("prism", "saturation"),          // explicit no-op branch in sendParam
            ("ambient", "color"),             // ambient engine is CT-only (sends xy: nil)
        ]
        for (cardID, paramID) in dead {
            let card = allCards.first { $0.id == cardID }
            XCTAssertNotNil(card, cardID)
            XCTAssertFalse(card!.params.contains { $0.id == paramID },
                           "\(cardID).\(paramID) is a dead param — removed by the 2026-07 audit")
        }
    }

    /// Every app-driven param id must be read by its engine loop (verified
    /// against UnifiedOrchestrator run* loops, 2026-07-09). Locks drift in
    /// both directions: catalogs can't grow dead sliders, and renames that
    /// break the engine key contract fail here.
    func testAppDrivenParamsMatchEngineReadKeys() {
        let engineReads: [String: Set<String>] = [
            "party": ["speed", "brightness", "min_brightness", "smoothness",
                      "color"],  // "color" wired as palette tint (C10, same round)
            "strobe": ["speed", "brightness", "min_brightness", "duty_cycle", "flash_color"],
            // R2 slice 5: the storm's remaining literals became params —
            // strike chance, flash frame count, afterglow, and the flash tint
            // (both engine paths; REST also honors ambient_color now).
            "thunderstorm": ["frequency", "flash_intensity", "min_brightness", "ambient_color",
                             "flash_color", "strike_rate", "flash_length", "afterglow"],
            "ambient": ["speed", "brightness", "warmth", "smoothness", "min_brightness"],
        ]
        for card in vm.liveModeCards {
            guard let allowed = engineReads[card.id] else {
                XCTFail("no engine-read allowlist for \(card.id)"); continue
            }
            for param in card.params {
                XCTAssertTrue(allowed.contains(param.id),
                              "\(card.id).\(param.id) is not read by the \(card.id) engine loop")
            }
        }
    }

    // ── Formatters ────────────────────────────────────────────

    /// The Hz readout mirrors the engine mapping (0.5–3.0 Hz) and therefore
    /// documents the WCAG ≤3 flashes/sec ceiling at full slider deflection.
    func testFlashHzFormatterMatchesEngineMappingAndWCAGCeiling() {
        XCTAssertEqual(StudioParamFormat.flashHz(0), "0.5 Hz")
        XCTAssertEqual(StudioParamFormat.flashHz(100), "3.0 Hz")
        XCTAssertEqual(StudioParamFormat.flashHz(150), "3.0 Hz")  // clamped
    }

    func testKelvinFormatterConvertsMirek() {
        XCTAssertEqual(StudioParamFormat.kelvin(366), "2700K")
        XCTAssertEqual(StudioParamFormat.kelvin(153), "6500K")
        XCTAssertEqual(StudioParamFormat.kelvin(500), "2000K")
    }

    /// Transition preset values must stay within the old slider's range —
    /// they feed the same `dynamics.duration` field.
    func testTransitionOptionsAreValidDurations() {
        for option in StudioParamFormat.transitionOptions {
            XCTAssertTrue((0...6000).contains(option.value), option.label)
        }
        // Every card's transition default must be one of the preset values,
        // so the segmented row's nearest-snap never moves a fresh default.
        let presetValues = Set(StudioParamFormat.transitionOptions.map(\.value))
        for card in allCards {
            guard let transition = card.params.first(where: { $0.id == "transition" }) else { continue }
            XCTAssertTrue(presetValues.contains(transition.defaultValue),
                          "\(card.id) transition default \(transition.defaultValue) is not a preset")
        }
    }

    // ── Composer deck sections ────────────────────────────────

    /// The All view's section order: the user's work always leads, Holiday is
    /// pinned second only while it is actually in season, `.all` never appears
    /// (it is a filter, not a category), and nothing is dropped or duplicated.
    func testComposerSectionOrderLeadsWithMyCreationsAndPinsSeasonalHoliday() {
        let real = PresetCategory.allCases.filter { $0 != .all }

        for inSeason in [true, false] {
            let order = StudioViewModel.sectionOrder(holidayInSeason: inSeason)
            XCTAssertEqual(order.first, .myCreations, "inSeason=\(inSeason)")
            XCTAssertFalse(order.contains(.all), "'.all' is a filter, not a section")
            XCTAssertEqual(Set(order), Set(real), "a category was dropped (inSeason=\(inSeason))")
            XCTAssertEqual(order.count, real.count, "a category was duplicated (inSeason=\(inSeason))")
        }

        XCTAssertEqual(StudioViewModel.sectionOrder(holidayInSeason: true)[1], .holiday,
                       "in season, Holiday sits right under the user's own work")
        XCTAssertNotEqual(StudioViewModel.sectionOrder(holidayInSeason: false)[1], .holiday,
                          "out of season, Holiday takes its normal chip-order place")
    }

    // ── Tray metrics ──────────────────────────────────────────

    /// Tray height is derived from content now — more inline rows must never
    /// produce a shorter tray, and the compact cap must hold.
    // DELETED in Track A C5 with `MixerTrayMetrics.engineHeight` /
    // `compactHeightCap`: they sized a fixed-height bottom-anchored tray, and
    // the customization host has no height to compute. `inlineParams` /
    // `overflowParams` are still covered by the tests around this one.

    // ── Three-row header ──────────────────────────────────────
    //
    // The tray header is icon/name/actions, then a badge lane, then (for
    // composition cards) a transport status sentence. These heights are
    // reserved, not measured, so if someone adds a row without paying for it
    // here the tray silently clips it — which is exactly the squeeze that
    // made the text wrap mid-word in the first place.

    /// The reserved header must cover the real intrinsic content: a 34pt
    /// action circle, the tray's top/bottom padding, and each extra row plus
    /// the 4pt spacing above it.
    func testHeaderBlockReservesRoomForEveryRow() {
        let actionCircle: CGFloat = 34
        let padding = HueSpacing.md + HueSpacing.sm

        let identityAndBadges = padding + actionCircle
            + HueSpacing.xs + MixerTrayMetrics.badgeLaneHeight
        XCTAssertGreaterThanOrEqual(
            MixerTrayMetrics.headerBlockHeight(hasStatusLine: false), identityAndBadges,
            "badge lane would be clipped")

        let withStatus = identityAndBadges + HueSpacing.xs + MixerTrayMetrics.statusLineHeight
        XCTAssertGreaterThanOrEqual(
            MixerTrayMetrics.headerBlockHeight(hasStatusLine: true), withStatus,
            "status sentence would be clipped")
    }

    /// A status line always costs height; engine cards never pay for one.
    func testStatusLineCostsHeightAndCompositionTrayPaysIt() {
        XCTAssertGreaterThan(MixerTrayMetrics.headerBlockHeight(hasStatusLine: true),
                             MixerTrayMetrics.headerBlockHeight(hasStatusLine: false))

        // The `compositionHeight` assertion that stood here died with the
        // fixed-height tray in Track A C5; the header arithmetic above is the
        // part that outlived it.
    }

    /// Inline + overflow must partition the catalog exactly — no param can
    /// be orphaned (unreachable from both the tray and the sheet reveal).
    func testInlineAndOverflowPartitionEveryCard() {
        for card in allCards {
            let inline = MixerTrayMetrics.inlineParams(for: card).map(\.id)
            let overflow = MixerTrayMetrics.overflowParams(for: card).map(\.id)
            XCTAssertEqual(Set(inline + overflow), Set(card.params.map(\.id)), card.id)
            XCTAssertTrue(Set(inline).isDisjoint(with: Set(overflow)), card.id)
        }
    }

    // ── ENT-only flags ────────────────────────────────────────

    /// Strobe's REST fallback runs a fixed 900 ms cycle and ignores these.
    func testStrobeEntOnlyFlags() {
        let strobe = vm.liveModeCards.first { $0.id == "strobe" }!
        for id in ["speed", "flash_color", "duty_cycle"] {
            XCTAssertTrue(strobe.params.first { $0.id == id }!.entOnly, id)
        }
        XCTAssertFalse(strobe.params.first { $0.id == "brightness" }!.entOnly)
    }
}
