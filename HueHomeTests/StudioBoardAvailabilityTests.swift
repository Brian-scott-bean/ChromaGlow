//
//  StudioBoardAvailabilityTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2 remediation R2 (one resolver truth
//  path for the board).
//
//  Before this funnel existed, `StudioBoardView` answered "may the user touch
//  this?" three different ways, and the app-driven answer was always "yes":
//  a colour picker on a colourless room, and Strobe's streaming-only flash
//  colour on a REST room, both rendered fully live while doing nothing. These
//  tests are the proof that the single funnel now answers for EVERY control on
//  the board, and that the copy the user reads matches the state.
//
//  Pure: no network, no clock, no sleeps.
//

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class StudioBoardAvailabilityTests: XCTestCase {

    private var vm: StudioViewModel!

    override func setUp() async throws {
        vm = StudioViewModel()
    }

    override func tearDown() async throws {
        vm = nil
    }

    // ── Builders ────────────────────────────────────────────────

    private func liveCard(_ id: String) -> StudioCard {
        let card = vm.liveModeCards.first { $0.id == id }
        XCTAssertNotNil(card, "\(id) is not in the shipping Live catalog")
        return card!
    }

    private func effectCard(_ id: String) -> StudioCard {
        let card = vm.effectCards.first { $0.id == id }
        XCTAssertNotNil(card, "\(id) is not in the shipping Effects catalog")
        return card!
    }

    private func param(_ card: StudioCard, _ paramID: String) -> StudioParam {
        let p = card.params.first { $0.id == paramID }
        XCTAssertNotNil(p, "\(card.id).\(paramID) is not declared")
        return p!
    }

    private func identity(for card: StudioCard) -> RunningLookIdentity {
        let execution: CustomizationExecution
        switch card.strategy {
        case .bridgeNative(let effect): execution = .bridgeNative(effect: effect)
        case .appDriven(let key):       execution = .appDriven(engineKey: key)
        case .composition(let pid):     execution = .composition(presetID: pid)
        }
        return RunningLookIdentity(bridgeID: "bridge-A",
                                   groupID: "room-1",
                                   kind: .room,
                                   cardID: card.id,
                                   execution: execution,
                                   generation: CustomizationGeneration(1))
    }

    /// A running target with per-axis coverage the caller dictates.
    private func target(card: StudioCard,
                        lights: Int = 3,
                        color: CapabilityCoverage? = nil,
                        transport: CustomizationTransport = .entertainment,
                        running: Bool = true) -> CustomizationTargetSnapshot {
        CustomizationTargetSnapshot(
            identity: identity(for: card),
            totalLights: lights,
            reachableLights: lights,
            dimming: .all(total: lights),
            color: color ?? .all(total: lights),
            colorTemperature: .all(total: lights),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .all(total: lights),
            effectsV2: .all(total: lights),
            verifiedEffectParameters: [:],
            entertainmentAvailable: .known,
            transport: transport,
            running: running)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 1. Colour hardware outranks everything
    // ──────────────────────────────────────────────────────────

    /// A bridge-native tint control on a room with no colour-capable lights.
    /// The old board rendered the swatch row live; the funnel disables it and
    /// says which HARDWARE fact is missing.
    func testBridgeNativeBaseColorOnColorlessTargetIsUnavailable() {
        let card = effectCard("opal")
        let colorParam = param(card, "base_color")
        let snapshot = target(card: card,
                              color: .none(total: 3),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(card: card, param: colorParam,
                                                         snapshot: snapshot)
        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.availability,
                       .unavailable(reason: .noColorCapableLights,
                                    remediation: .addCapableLights))
        XCTAssertEqual(StudioBoardAvailability.isInteractive(resolution!.availability), false)
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "NO COLOR LIGHTS HERE")
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "NO COLOR LIGHTS HERE")
    }

    /// Hardware "no" must outrank the transport note: a colourless room that
    /// is ALSO on REST must not be told to turn streaming on.
    func testStreamingOnlyColorOnColorlessTargetReportsTheHardwareReason() {
        let card = liveCard("strobe")
        let flashColor = param(card, "flash_color")
        let snapshot = target(card: card, color: .none(total: 3), transport: .roomREST)

        let resolution = StudioBoardAvailability.resolve(card: card, param: flashColor,
                                                         snapshot: snapshot)
        XCTAssertEqual(resolution?.availability,
                       .unavailable(reason: .noColorCapableLights,
                                    remediation: .addCapableLights))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 2. Streaming-only colour on REST is STAGED, not live
    // ──────────────────────────────────────────────────────────

    /// `strobe.flash_color` is entOnly: the REST fallback loop ignores it.
    /// Spec §17 calls this staged — editable and saved, honestly labelled —
    /// NOT a live control and NOT a disabled one.
    func testStrobeFlashColorOnRoomRESTIsStagedAndEditable() {
        let card = liveCard("strobe")
        let flashColor = param(card, "flash_color")
        XCTAssertTrue(flashColor.entOnly)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: flashColor,
            snapshot: target(card: card, transport: .roomREST))

        XCTAssertEqual(resolution?.availability,
                       .staged(reason: .requiresEntertainment, remediation: .enableStreaming))
        XCTAssertEqual(resolution?.behavior, .staged)
        XCTAssertTrue(StudioBoardAvailability.isInteractive(resolution!.availability))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "STREAMING ONLY — INACTIVE IN ROOM MODE")
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution!.availability),
                       StudioBoardAvailability.stagedOpacity)
    }

    /// The same control while the look really is streaming: fully live.
    func testStrobeFlashColorWhileStreamingIsActive() {
        let card = liveCard("strobe")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "flash_color"),
            snapshot: target(card: card, transport: .entertainment))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertTrue(StudioBoardAvailability.isInteractive(resolution!.availability))
        XCTAssertNil(StudioBoardAvailability.note(for: resolution!, isColor: true))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 3. Partial colour coverage
    // ──────────────────────────────────────────────────────────

    /// One of three lights does colour. The control stays usable and states
    /// its coverage — but the colour SECTION suppresses the text, because the
    /// editor already badges "1 OF 3 LIGHTS" beside its chip.
    func testPartyColorWithPartialCoverageIsPartialAndEditable() {
        let card = liveCard("party")
        let colorParam = param(card, "color")
        XCTAssertFalse(colorParam.entOnly)

        let coverage = CapabilityCoverage(supported: 1, total: 3, evidence: .known)
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: colorParam,
            snapshot: target(card: card, color: coverage))

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
        XCTAssertTrue(StudioBoardAvailability.isInteractive(resolution!.availability))
        XCTAssertNil(StudioBoardAvailability.note(for: resolution!, isColor: true),
                     "the editor already badges coverage; two notes read as two problems")
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "1 OF 3 LIGHTS RESPOND")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 4. Unknown is never unsupported
    // ──────────────────────────────────────────────────────────

    /// The snapshot the view model builds when the light cache is empty. The
    /// old board could not tell this apart from full coverage; the funnel
    /// disables the control and says we are still checking.
    func testUnreadableSnapshotResolvesUnavailableWithRetry() {
        let card = liveCard("party")
        let snapshot = CustomizationSnapshotBuilder.unreadable(
            identity: identity(for: card), totalLights: 3,
            transport: .entertainment, running: true)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "color"), snapshot: snapshot)

        guard case .unavailable(let reason, let remediation)? = resolution?.availability else {
            return XCTFail("expected unavailable, got \(String(describing: resolution?.availability))")
        }
        XCTAssertTrue(reason == .capabilityUnknown || reason == .capabilityUnreadable,
                      "unreadable must stay in the unknown family, got \(reason)")
        XCTAssertEqual(remediation, .retryCapabilityFetch)
        XCTAssertFalse(StudioBoardAvailability.isInteractive(resolution!.availability))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "CHECKING WHAT THESE LIGHTS SUPPORT")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 5/6. Numeric controls follow the same rule
    // ──────────────────────────────────────────────────────────

    /// A numeric param the REST loop really does read: active on REST. The
    /// funnel must not disable every Live control just because it is not
    /// streaming.
    func testNonStreamingNumericParamIsActiveOnREST() {
        let card = liveCard("thunderstorm")
        let frequency = param(card, "frequency")
        XCTAssertFalse(frequency.entOnly)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: frequency,
            snapshot: target(card: card, transport: .roomREST))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertEqual(resolution?.behavior, .immediate)
        XCTAssertNil(StudioBoardAvailability.note(for: resolution!, isColor: false))
    }

    /// A streaming-only NUMERIC param aligns with the colour rule: staged and
    /// editable. The old board disabled these, discarding the user's value
    /// instead of holding it for the moment streaming arrives.
    func testStreamingOnlyNumericParamIsStagedAndEditableOnREST() {
        let card = liveCard("strobe")
        let duty = param(card, "duty_cycle")
        XCTAssertTrue(duty.entOnly)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: duty,
            snapshot: target(card: card, transport: .roomREST))

        XCTAssertEqual(resolution?.availability,
                       .staged(reason: .requiresEntertainment, remediation: .enableStreaming))
        XCTAssertTrue(StudioBoardAvailability.isInteractive(resolution!.availability))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "STREAMING ONLY — INACTIVE IN ROOM MODE")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 7. No Live control escapes the resolver
    // ──────────────────────────────────────────────────────────

    /// THE regression this whole lane exists for: `resolution(for:)` used to
    /// return nil for every app-driven param, and nil meant "interactive".
    /// Every declared Live-card control must now produce a real resolution.
    func testEveryLiveCardParamResolvesThroughTheFunnel() {
        for card in vm.liveModeCards {
            guard case .appDriven = card.strategy else {
                XCTFail("liveModeCards must all be app-driven: \(card.id)"); continue
            }
            let snapshot = target(card: card, transport: .roomREST)
            for p in card.params {
                XCTAssertNotNil(StudioBoardAvailability.descriptor(card: card, param: p),
                                "\(card.id).\(p.id) has no descriptor")
                XCTAssertNotNil(StudioBoardAvailability.resolve(card: card, param: p,
                                                                snapshot: snapshot),
                                "\(card.id).\(p.id) escapes the resolver")
            }
        }
    }

    /// Every `entOnly` param — and only those — carries the Entertainment
    /// transport requirement. This is the flag→requirement migration made
    /// checkable at the funnel rather than asserted in a comment.
    func testEntOnlyParamsCarryTheEntertainmentTransportRequirement() {
        for card in vm.liveModeCards {
            for p in card.params {
                guard let descriptor = StudioBoardAvailability.descriptor(card: card,
                                                                          param: p) else {
                    return XCTFail("\(card.id).\(p.id) has no descriptor")
                }
                let requiresENT = Self.mentionsEntertainmentTransport(descriptor.requirement)
                XCTAssertEqual(requiresENT, p.entOnly,
                               "\(card.id).\(p.id): entOnly=\(p.entOnly) but requirement=\(descriptor.requirement)")
            }
        }
    }

    private static func mentionsEntertainmentTransport(_ requirement: CapabilityRequirement) -> Bool {
        switch requirement {
        case .transport(let t):          return t == .entertainment
        case .all(let parts), .any(let parts):
            return parts.contains { mentionsEntertainmentTransport($0) }
        default:                          return false
        }
    }

    // ── Composition boards stay Composer-owned ──────────────────

    /// Composition cards are not resolver-governed here — nil, exactly as
    /// before. (They declare no board params, so this is a shape lock.)
    func testCompositionCardsProduceNoDescriptor() {
        let composition = StudioCard(
            id: "composition-fixture",
            name: "Fixture",
            tagline: "",
            icon: "circle",
            accentColor: .white,
            requiresForeground: true,
            params: [StudioParam(id: "brightness", label: "Brightness",
                                 kind: .slider(min: 1, max: 100),
                                 defaultValue: 50, tier: .essential)],
            strategy: .composition(presetID: UUID()),
            compositionLayerActivity: nil)

        XCTAssertNil(StudioBoardAvailability.descriptor(card: composition,
                                                        param: composition.params[0]))
    }
}
