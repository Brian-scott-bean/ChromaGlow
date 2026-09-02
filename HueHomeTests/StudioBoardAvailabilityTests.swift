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
    ///
    /// `effectV2ColorLights`/`effectV2CTLights` default to nil — the snapshot
    /// shape a target with nothing bridge-native running (or an unreadable
    /// read) really has, where the funnel falls back to the `min`. Tests that
    /// are ABOUT the intersection pass them explicitly.
    private func target(card: StudioCard,
                        lights: Int = 3,
                        color: CapabilityCoverage? = nil,
                        colorTemperature: CapabilityCoverage? = nil,
                        effectsV2: CapabilityCoverage? = nil,
                        effectV2ColorLights: Int? = nil,
                        effectV2CTLights: Int? = nil,
                        transport: CustomizationTransport = .entertainment,
                        running: Bool = true) -> CustomizationTargetSnapshot {
        CustomizationTargetSnapshot(
            identity: identity(for: card),
            totalLights: lights,
            reachableLights: lights,
            dimming: .all(total: lights),
            color: color ?? .all(total: lights),
            colorTemperature: colorTemperature ?? .all(total: lights),
            mirekRange: MirekRange(minMirek: 153, maxMirek: 500),
            gradient: .all(total: lights),
            effectsV2: effectsV2 ?? .all(total: lights),
            effectV2ColorLights: effectV2ColorLights,
            effectV2CTLights: effectV2CTLights,
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
        // Through the funnel too: staged is one of the two states that still
        // earns the dimming, so relaxing it for the hardware-unverified case
        // must not relax it here.
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy),
                       StudioBoardAvailability.stagedOpacity)
    }

    /// Dimming means "you cannot use this right now", and ONLY that. The
    /// funnel's opacity must answer purely from availability — a control that
    /// works is at full strength even while it owes a hardware check, and a
    /// control the funnel refused is quiet even when it owes nothing.
    func testOpacityAnswersFromAvailabilityAloneNotFromEvidence() {
        let card = effectCard("opal")
        let strategy = card.strategy
        for unverified in [true, false] {
            let cases: [(CustomizationAvailability, Double)] = [
                (.active, 1),
                (.partial(supported: 1, total: 3, reason: .partialHardwareCoverage), 1),
                (.staged(reason: .requiresEntertainment, remediation: .enableStreaming),
                 StudioBoardAvailability.stagedOpacity),
                (.unavailable(reason: .noColorCapableLights, remediation: nil),
                 StudioBoardAvailability.disabledOpacity),
            ]
            for (availability, expected) in cases {
                let resolution = StudioBoardResolution(
                    resolution: CustomizationResolution(
                        control: CustomizationControlID(cardID: card.id, paramID: "speed"),
                        availability: availability,
                        behavior: .debounced),
                    isHardwareUnverified: unverified,
                    totalLights: 3)
                XCTAssertEqual(
                    StudioBoardAvailability.opacity(resolution: resolution,
                                                    strategy: strategy),
                    expected,
                    "\(availability) with isHardwareUnverified=\(unverified)")
            }
        }
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
                       StudioBoardAvailability.checkingCopy,
                       "unknown must read as still-checking, never as a hardware refusal")
        XCTAssertEqual(StudioBoardAvailability.checkingCopy,
                       "CHECKING WHAT THESE LIGHTS SUPPORT",
                       "the caption must fit two lines under a knob in a three-column grid")
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

    // ──────────────────────────────────────────────────────────
    // MARK: - 8. Evidence survives the funnel (audit §7)
    // ──────────────────────────────────────────────────────────

    /// `brightness` on a bridge-native effect is a GROUPED light-state write.
    /// The send is code-proven; whether it visibly scales a running firmware
    /// effect is the hardware check `EffectParameterProfiles` still owes. The
    /// first cut of this funnel threw `profile.evidence` away, so the control
    /// rendered fully live with no note — the exact thing the capability
    /// matrix says must not happen. It stays EDITABLE (the write ships), but
    /// it says what it does not know.
    func testHardwarePendingBrightnessIsEditableButLabelledUnverified() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "brightness"),
            snapshot: target(card: card, transport: .bridgeEffectV2))

        XCTAssertEqual(resolution?.availability, .active,
                       "the send path works — nothing here may take the control away")
        XCTAssertEqual(resolution?.isHardwareUnverified, true)
        XCTAssertTrue(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "UNVERIFIED ON THESE LIGHTS")
        // FULL STRENGTH. Dimming is reserved for "you cannot use this right
        // now"; this control is fully live and fully working, and the one
        // thing that is unknown about it is said in words beside it. The first
        // cut quieted every `isHardwareUnverified` control to `stagedOpacity`,
        // and since `brightness` and `speed` owe a check on every transport,
        // that made EVERY bridge-native board — hero knob included — read as
        // half-disabled.
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy), 1,
                       "a working control must not be dimmed for owing a hardware check")
    }

    /// `base_color` is code-proven only on its per-light `effects_v2` path. On
    /// a v1-only room the shipping fallback is a grouped xy write — an
    /// approximation whose behaviour against a running firmware effect is
    /// still a pending hardware check.
    func testBaseColorOnV1OnlyRoomIsLabelledUnverified() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"),
            snapshot: target(card: card, transport: .legacy))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertEqual(resolution?.isHardwareUnverified, true)
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "UNVERIFIED ON THESE LIGHTS",
                       "the colour section suppresses COVERAGE, never the evidence caveat")
    }

    /// The same control on a room whose lights took `effects_v2`: the
    /// per-light path IS the proof, so this one is fully live and silent.
    func testBaseColorOnV2RoomIsFullyLiveAndSilent() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"),
            snapshot: target(card: card, transport: .bridgeEffectV2))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertEqual(resolution?.isHardwareUnverified, false)
        XCTAssertNil(StudioBoardAvailability.note(for: resolution!, isColor: true))
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy), 1)
    }

    /// A control the resolver has already refused says the refusal, not the
    /// caveat: two problems stacked on one control read as two problems.
    func testUnavailableControlDoesNotAlsoClaimUnverified() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"),
            snapshot: target(card: card, color: .none(total: 3), transport: .legacy))

        XCTAssertEqual(resolution?.isHardwareUnverified, false)
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "NO COLOR LIGHTS HERE")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 9. App-driven numerics that are really hardware axes
    // ──────────────────────────────────────────────────────────

    /// `ambient.warmth` is a mirek slider. Its catalog kind is `.slider`, so
    /// the first cut — which translated only `entOnly` — resolved it `.active`
    /// on a room with no CT-capable light at all, writing colour temperature
    /// into fixtures that cannot honour it.
    func testAmbientWarmthWithoutCTCapableLightsIsUnavailable() {
        let card = liveCard("ambient")
        let warmth = param(card, "warmth")
        XCTAssertFalse(warmth.entOnly)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: warmth,
            snapshot: target(card: card, colorTemperature: .none(total: 3),
                             transport: .roomREST))

        XCTAssertEqual(resolution?.availability,
                       .unavailable(reason: .noCTCapableLights,
                                    remediation: .addCapableLights))
        XCTAssertFalse(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "NO WHITE-TONE LIGHTS HERE")
    }

    /// …and on a room that CAN do white tones it is live as before. The gate
    /// is the hardware fact, not the param name.
    func testAmbientWarmthWithCTCapableLightsStaysActive() {
        let card = liveCard("ambient")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "warmth"),
            snapshot: target(card: card, transport: .roomREST))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertNil(StudioBoardAvailability.note(for: resolution!, isColor: false))
    }

    /// Dimming stays universal: adding a hardware gate to Brightness would put
    /// a caveat on every Live card for nothing.
    func testAppDrivenBrightnessCarriesNoHardwareRequirement() {
        let card = liveCard("ambient")
        let descriptor = StudioBoardAvailability.descriptor(card: card,
                                                            param: param(card, "brightness"))
        XCTAssertEqual(descriptor?.requirement, CapabilityRequirement.none)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 10. The nil answer, and the empty room
    // ──────────────────────────────────────────────────────────

    /// nil used to mean "interactive". For a bridge-native param absent from
    /// the audit-§7 table that is fail-OPEN: there is no proven send path at
    /// all, so a live-looking control is the original defect in a new place.
    func testUnprofiledBridgeNativeParamIsNotInteractive() {
        let card = StudioCard(
            id: "opal", name: "Opal", tagline: "", icon: "circle",
            accentColor: .white, requiresForeground: true,
            params: [StudioParam(id: "not_in_the_table", label: "Mystery",
                                 kind: .slider(min: 0, max: 1),
                                 defaultValue: 0, tier: .support)],
            strategy: .bridgeNative(effect: "opal"),
            compositionLayerActivity: nil)
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: card.params[0],
            snapshot: target(card: card, transport: .bridgeEffectV2))

        XCTAssertNil(resolution, "no profile — the funnel has nothing to stand on")
        XCTAssertFalse(StudioBoardAvailability.isInteractive(resolution: resolution,
                                                             strategy: card.strategy))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution, strategy: card.strategy,
                                                    isColor: false),
                       "NOT AVAILABLE FOR THESE LIGHTS")
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy),
                       StudioBoardAvailability.disabledOpacity)
    }

    /// Composition boards keep the old nil answer: they declare no params
    /// here, so nil means "not this funnel's business", not "unproven".
    func testNilOnACompositionCardStaysInteractive() {
        let strategy = StudioStrategy.composition(presetID: UUID())
        XCTAssertTrue(StudioBoardAvailability.isInteractive(resolution: nil,
                                                            strategy: strategy))
        XCTAssertNil(StudioBoardAvailability.note(for: nil, strategy: strategy,
                                                  isColor: false))
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: nil, strategy: strategy), 1)
    }

    /// A target with no lights is not "still checking" — nothing will ever
    /// answer. CHECKING there is a spinner that never resolves.
    func testTargetWithNoLightsSaysThereAreNone() {
        let card = liveCard("party")
        let snapshot = CustomizationSnapshotBuilder.unreadable(
            identity: identity(for: card), totalLights: 0,
            transport: .roomREST, running: true)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "color"), snapshot: snapshot)

        XCTAssertFalse(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "NO LIGHTS HERE")
    }

    /// Hidden is "do not render", not "render dimmed" (spec §17). The board
    /// asks this before it builds anything.
    func testHiddenResolutionRendersNothing() {
        let hidden = StudioBoardResolution(
            resolution: CustomizationResolution(
                control: CustomizationControlID(cardID: "party", paramID: "color"),
                availability: .hidden, behavior: .staged),
            isHardwareUnverified: false,
            totalLights: 3)

        XCTAssertFalse(StudioBoardAvailability.rendersControl(hidden))
        XCTAssertTrue(StudioBoardAvailability.rendersControl(nil),
                      "a control the funnel does not govern still renders")
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

    // ──────────────────────────────────────────────────────────
    // MARK: - 11. Unknown is never a refusal (B1)
    // ──────────────────────────────────────────────────────────

    /// THE regression this section exists for. `speed` requires `.effectsV2`,
    /// and the resolver used to map an UNKNOWN `.effectsV2` to the SAME reason
    /// as an unsupported one — so on a cold or unreadable snapshot the Speed
    /// knob asserted "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING" (a
    /// hardware refusal we had read nothing to justify) while
    /// brightness/base_color/warmth beside it, on the very same snapshot,
    /// correctly said we were still checking. One snapshot must tell one story.
    func testUnreadableSnapshotSpeedSaysCheckingNotARefusal() {
        let card = effectCard("opal")
        let snapshot = CustomizationSnapshotBuilder.unreadable(
            identity: identity(for: card), totalLights: 3,
            transport: .bridgeEffectV2, running: true)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "speed"), snapshot: snapshot)

        guard case .unavailable(let reason, let remediation)? = resolution?.availability else {
            return XCTFail("expected unavailable, got \(String(describing: resolution?.availability))")
        }
        XCTAssertTrue(reason == .capabilityUnknown || reason == .capabilityUnreadable,
                      "an unread effects_v2 must stay in the unknown family, got \(reason)")
        XCTAssertNotEqual(reason, .effectsV2Unavailable,
                          "effectsV2Unavailable is the UNSUPPORTED answer — it may not be reached from unknown")
        XCTAssertEqual(remediation, .retryCapabilityFetch)
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       StudioBoardAvailability.checkingCopy)
    }

    /// Every control on that same cold snapshot tells the same story. This is
    /// the assertion the old mapping broke: three siblings saying CHECKING and
    /// one saying the lights refuse.
    func testEveryBridgeNativeParamOnAnUnreadableSnapshotSaysChecking() {
        let card = effectCard("opal")
        let snapshot = CustomizationSnapshotBuilder.unreadable(
            identity: identity(for: card), totalLights: 3,
            transport: .bridgeEffectV2, running: true)

        for p in card.params where p.id != "transition" {
            guard let resolution = StudioBoardAvailability.resolve(
                card: card, param: p, snapshot: snapshot) else { continue }
            XCTAssertEqual(StudioBoardAvailability.note(for: resolution, isColor: false),
                           StudioBoardAvailability.checkingCopy,
                           "\(card.id).\(p.id) breaks ranks on a snapshot nobody could read")
        }
    }

    /// `.effectParameter` keeps its own reason, and the board must render the
    /// UNKNOWN flavour of it as checking too. The unsupported flavour — the
    /// effect really has no such parameter — carries no remediation and stays
    /// a plain "not available".
    func testUnverifiedEffectParameterReadsAsCheckingNotAsARefusal() {
        let unknown = StudioBoardResolution(
            resolution: CustomizationResolution(
                control: CustomizationControlID(cardID: "opal", paramID: "tint"),
                availability: .unavailable(reason: .effectParameterUnverified,
                                           remediation: .retryCapabilityFetch),
                behavior: .staged),
            isHardwareUnverified: false, totalLights: 3)
        let unsupported = StudioBoardResolution(
            resolution: CustomizationResolution(
                control: CustomizationControlID(cardID: "opal", paramID: "tint"),
                availability: .unavailable(reason: .effectParameterUnverified,
                                           remediation: nil),
                behavior: .staged),
            isHardwareUnverified: false, totalLights: 3)

        XCTAssertEqual(StudioBoardAvailability.note(for: unknown, isColor: false),
                       StudioBoardAvailability.checkingCopy)
        XCTAssertEqual(StudioBoardAvailability.note(for: unsupported, isColor: false),
                       "NOT AVAILABLE FOR THESE LIGHTS")
    }

    /// The refusal copy is still reachable — from the UNSUPPORTED branch only.
    func testUnsupportedEffectsV2StillSaysTheLightsRefuse() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "speed"),
            snapshot: target(card: card, effectsV2: .none(total: 3),
                             transport: .legacy))

        XCTAssertEqual(resolution?.availability,
                       .unavailable(reason: .effectsV2Unavailable,
                                    remediation: .addCapableLights))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 12. Mixed v2/v1 rooms state their real reach (H2)
    // ──────────────────────────────────────────────────────────

    /// One v2-capable light and two legacy ones, all colour-capable, running
    /// Opal. `performBridgeSend` writes the per-light `effects_v2` body only
    /// to the capable ids, so exactly ONE light moves — but the snapshot calls
    /// the whole target `.bridgeEffectV2` (one capable light is enough), and
    /// the resolver measured full COLOUR coverage, so the control claimed the
    /// room. The legacy-only caveat could not catch it either: the room is not
    /// `.legacy`. Coverage is the honest answer.
    func testBaseColorInAMixedV2RoomStatesItsRealCoverage() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
        XCTAssertTrue(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy),
                      "partial stays editable — the one capable light really does respond")
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "1 OF 3 LIGHTS RESPOND")
    }

    /// `warmth` reaches the same lights by the same path, so it gets the same
    /// answer even though its requirement is CT, not colour.
    func testWarmthInAMixedV2RoomStatesItsRealCoverage() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "warmth"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
    }

    /// The narrowing only ever NARROWS, and it narrows to the INTERSECTION.
    ///
    /// Four lights: three take this effect's `effects_v2` body, one renders
    /// colour — and it is one of the three. The true reach of `base_color` is
    /// therefore 1, which is also what `min(3, 1)` happens to say here, so the
    /// snapshot's own count is what makes the claim rather than the arithmetic
    /// coincidence.
    func testNarrowerCapabilityCoverageOutranksTheV2Subset() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 4,
                              color: CapabilityCoverage(supported: 1, total: 4,
                                                        evidence: .known),
                              effectsV2: CapabilityCoverage(supported: 3, total: 4,
                                                            evidence: .known),
                              effectV2ColorLights: 1,
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 4, reason: .partialHardwareCoverage))
    }

    /// The intersection is not the minimum, and this is the room that proves
    /// it: ONE white-ambiance light that runs the effect, TWO colour lights
    /// that do not. `effects_v2` reach is 1, colour coverage is 2, and
    /// `min(1, 2) = 1` — so the pre-intersection funnel captioned the swatch
    /// row "1 OF 3 LIGHTS RESPOND" and left it live, when the honest answer is
    /// that the one reachable light cannot render colour and the two colour
    /// lights never receive the write. Nothing responds.
    func testColourControlWithNoLightInBothSetsIsRefused() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              color: CapabilityCoverage(supported: 2, total: 3,
                                                        evidence: .known),
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              effectV2ColorLights: 0,
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"), snapshot: snapshot)

        // A refusal, not "0 OF 3 LIGHTS RESPOND": `.partial(supported: 0)` is
        // an EDITABLE control that moves and changes nothing, which is the
        // defect this whole funnel exists to close.
        XCTAssertEqual(resolution?.availability,
                       .unavailable(reason: .partialHardwareCoverage,
                                    remediation: .addCapableLights))
        XCTAssertFalse(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy))
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy),
                       StudioBoardAvailability.disabledOpacity)
        // NOT "NO COLOR LIGHTS HERE" — there are two, and saying otherwise
        // would be a false claim about the inventory. What is true is that
        // none of them responds to THIS control.
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "NO LIGHT HERE RESPONDS TO THIS")
        // A refusal is one problem, not two: the evidence caveat stays off.
        XCTAssertEqual(resolution?.isHardwareUnverified, false)
    }

    /// The same room for `warmth`, through the CT intersection: the one light
    /// that runs the effect is white-ambiance, so warmth DOES reach it.
    func testWarmthReachesTheOneEffectCapableWhiteLight() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              color: CapabilityCoverage(supported: 2, total: 3,
                                                        evidence: .known),
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              effectV2ColorLights: 0,
                              effectV2CTLights: 1,
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "warmth"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
        XCTAssertTrue(StudioBoardAvailability.isInteractive(
            resolution: resolution, strategy: card.strategy),
                      "the intersection is per-axis — colour's zero must not take warmth down with it")
    }

    /// `speed` is not a per-light capability, so it intersects with nothing:
    /// the effect-specific v2 subset is its whole reach, whatever colour and
    /// CT do.
    func testSpeedIgnoresTheColourAndCTIntersections() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              color: CapabilityCoverage(supported: 2, total: 3,
                                                        evidence: .known),
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              effectV2ColorLights: 0,
                              effectV2CTLights: 0,
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "speed"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
    }

    /// Nil intersections are the snapshot saying "never computed", not "zero".
    /// The funnel falls back to the `min` there — the pre-intersection answer —
    /// so a target with nothing bridge-native running keeps its old behaviour
    /// instead of resolving every colour control into a refusal.
    func testUncomputedIntersectionsFallBackToTheMinimum() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              color: CapabilityCoverage(supported: 2, total: 3,
                                                        evidence: .known),
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"), snapshot: snapshot)

        XCTAssertNil(snapshot.effectV2ColorLights)
        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
    }

    /// `brightness` is a GROUPED write — it reaches the whole room whatever
    /// the v2 split is, so it must NOT be narrowed.
    func testGroupedBrightnessIsNotNarrowedByTheV2Subset() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "brightness"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability, .active,
                       "the grouped light-state write reaches every light in the room")
    }

    /// A v1-only room is still the legacy caveat's business, not coverage's:
    /// `isPartial` is false there (nothing is v2-capable), so the control
    /// stays active-but-unverified rather than "0 of 3".
    func testFullyLegacyRoomKeepsTheGroupedFallbackCaveat() {
        let card = effectCard("opal")
        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "base_color"),
            snapshot: target(card: card, effectsV2: .none(total: 3),
                             transport: .legacy))

        XCTAssertEqual(resolution?.availability, .active)
        XCTAssertEqual(resolution?.isHardwareUnverified, true)
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "UNVERIFIED ON THESE LIGHTS")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 13. The pending-check list is the single source (M4/M5)
    // ──────────────────────────────────────────────────────────

    /// `speed` owes a per-effect, per-model firmware-response check — it is in
    /// `pendingHardwareChecks` and always has been — but the funnel's own
    /// hardcoded rule ("`.hardwarePending` evidence, or the grouped fallback
    /// pair") silently omitted it, so the HERO knob of every bridge-native
    /// board rendered as fully vouched-for.
    func testSpeedIsLabelledUnverifiedOnEveryTransport() {
        let card = effectCard("opal")
        for transport in [CustomizationTransport.bridgeEffectV2, .legacy] {
            let effectsV2: CapabilityCoverage =
                transport == .legacy ? .none(total: 3) : .all(total: 3)
            let resolution = StudioBoardAvailability.resolve(
                card: card, param: param(card, "speed"),
                snapshot: target(card: card, effectsV2: effectsV2, transport: transport))
            guard let resolution else { return XCTFail("speed must resolve") }
            guard case .active = resolution.availability else {
                // On legacy there is no v2 path at all — that is the refusal
                // case, already covered above.
                XCTAssertEqual(transport, .legacy)
                continue
            }
            XCTAssertTrue(resolution.isHardwareUnverified,
                          "speed owes a hardware check on \(transport)")
        }
    }

    /// The membership question has ONE answer, and it lives in
    /// `EffectParameterProfiles`. If a check is added or retired there, the
    /// board's label follows without a second edit.
    func testUnverifiedLabelTracksThePendingHardwareCheckList() {
        let card = effectCard("opal")
        let pending = EffectParameterProfiles.pendingHardwareCheckParamIDs
        let snapshot = target(card: card, transport: .bridgeEffectV2)

        for p in card.params {
            guard let resolution = StudioBoardAvailability.resolve(
                card: card, param: p, snapshot: snapshot),
                  case .active = resolution.availability else { continue }
            let owedHere = pending.contains(p.id)
                && !EffectParameterProfiles.groupedFallbackOnlyChecks.contains(p.id)
            XCTAssertEqual(resolution.isHardwareUnverified, owedHere,
                           "\(card.id).\(p.id) disagrees with pendingHardwareChecks")
        }
    }

    /// The two lists in `EffectParameterProfiles` must agree: a scope entry
    /// naming a param that owes no check is a rule about nothing.
    func testGroupedFallbackScopeIsASubsetOfThePendingChecks() {
        XCTAssertTrue(EffectParameterProfiles.groupedFallbackOnlyChecks
            .isSubset(of: EffectParameterProfiles.pendingHardwareCheckParamIDs),
                      "a grouped-fallback scope entry must name a param that owes a check")
        XCTAssertEqual(EffectParameterProfiles.pendingHardwareCheckParamIDs,
                       ["brightness", "base_color", "warmth", "speed"],
                       "the checklist changed — the board's labels move with it, on purpose")
    }

    /// Coverage and the evidence caveat are DIFFERENT facts: which lights, and
    /// whether. The first cut returned the caveat and dropped the count, so a
    /// mixed room's `speed` lost the far more actionable "1 OF 3 LIGHTS
    /// RESPOND".
    func testCoverageAndTheUnverifiedCaveatCoexist() {
        let card = effectCard("opal")
        let snapshot = target(card: card, lights: 3,
                              effectsV2: CapabilityCoverage(supported: 1, total: 3,
                                                            evidence: .known),
                              transport: .bridgeEffectV2)

        let resolution = StudioBoardAvailability.resolve(
            card: card, param: param(card, "speed"), snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .partial(supported: 1, total: 3, reason: .partialHardwareCoverage))
        XCTAssertEqual(resolution?.isHardwareUnverified, true)
        // JOINED, the caveat says it in fewer words. The long form made a
        // 50-character caption that has to fit under a 60 pt knob in a
        // three-column grid; it overran the caption's line budget and the
        // clipped tail was the caveat itself. The coverage clause has already
        // named the lights, so the caveat only has to say WHETHER.
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "1 OF 3 LIGHTS RESPOND · UNVERIFIED HERE")
        // The colour section suppresses COVERAGE only; the caveat survives,
        // because nothing else on screen is saying it — and standing alone it
        // has the whole line, so it names the lights again.
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: true),
                       "UNVERIFIED ON THESE LIGHTS")
    }

    /// The two forms are the SAME fact, and the short one is only ever used
    /// where the coverage count is carrying the "which lights".
    func testTheJoinedCaveatIsTheShortFormAndTheLoneCaveatIsTheLong() {
        XCTAssertEqual(StudioBoardAvailability.unverifiedCopy,
                       "UNVERIFIED ON THESE LIGHTS")
        XCTAssertEqual(StudioBoardAvailability.unverifiedJoinedCopy, "UNVERIFIED HERE")
        XCTAssertLessThan(StudioBoardAvailability.unverifiedJoinedCopy.count,
                          StudioBoardAvailability.unverifiedCopy.count,
                          "the joined form exists to be shorter — if it is not, drop it")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 14. An empty room outranks every availability (L9)
    // ──────────────────────────────────────────────────────────

    /// "NO LIGHTS HERE" used to live inside the `.unavailable` branch only, so
    /// a STAGED control on an empty room still promised that streaming would
    /// make it work. There is nothing here for streaming to reach.
    func testEmptyRoomOutranksAStagedTransportNote() {
        let card = liveCard("strobe")
        let duty = param(card, "duty_cycle")
        let snapshot = target(card: card, lights: 0, transport: .roomREST)

        let resolution = StudioBoardAvailability.resolve(card: card, param: duty,
                                                         snapshot: snapshot)

        XCTAssertEqual(resolution?.availability,
                       .staged(reason: .requiresEntertainment, remediation: .enableStreaming))
        XCTAssertEqual(StudioBoardAvailability.note(for: resolution!, isColor: false),
                       "NO LIGHTS HERE")
    }

    /// …and over a partial count, which on an empty room can only ever read
    /// as "0 OF 0 LIGHTS RESPOND".
    func testEmptyRoomOutranksAPartialCount() {
        let empty = StudioBoardResolution(
            resolution: CustomizationResolution(
                control: CustomizationControlID(cardID: "party", paramID: "color"),
                availability: .partial(supported: 0, total: 0,
                                       reason: .partialHardwareCoverage),
                behavior: .immediate),
            isHardwareUnverified: true, totalLights: 0)

        XCTAssertEqual(StudioBoardAvailability.note(for: empty, isColor: false),
                       "NO LIGHTS HERE")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 15. The strategy-qualified note on real resolutions (L10)
    // ──────────────────────────────────────────────────────────

    /// The 3-arg overload is what both renderers actually call. Its nil branch
    /// is well covered; its NON-nil branch — the one every live control takes
    /// — was only ever exercised through the 2-arg form.
    func testStrategyQualifiedNoteDelegatesForEveryRealResolution() {
        let cases: [(StudioCard, String, CustomizationTargetSnapshot)] = [
            (liveCard("strobe"), "duty_cycle",
             target(card: liveCard("strobe"), transport: .roomREST)),
            (liveCard("party"), "color",
             target(card: liveCard("party"), color: .none(total: 3))),
            (effectCard("opal"), "brightness",
             target(card: effectCard("opal"), transport: .bridgeEffectV2)),
            (effectCard("opal"), "base_color",
             target(card: effectCard("opal"), lights: 3,
                    effectsV2: CapabilityCoverage(supported: 1, total: 3, evidence: .known),
                    transport: .bridgeEffectV2)),
        ]
        for (card, paramID, snapshot) in cases {
            let resolution = StudioBoardAvailability.resolve(
                card: card, param: param(card, paramID), snapshot: snapshot)
            XCTAssertNotNil(resolution, "\(card.id).\(paramID)")
            for isColor in [true, false] {
                XCTAssertEqual(
                    StudioBoardAvailability.note(for: resolution,
                                                 strategy: card.strategy, isColor: isColor),
                    StudioBoardAvailability.note(for: resolution!, isColor: isColor),
                    "\(card.id).\(paramID) isColor=\(isColor): the strategy overload must "
                    + "delegate, not answer for itself, once there IS a resolution")
            }
        }
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 16. Colour context reads the board's snapshot (L11)
    // ──────────────────────────────────────────────────────────

    /// The colour chip's coverage must come from the SAME snapshot the board
    /// resolved against — including its evidence. A chip that rebuilt `.known`
    /// coverage for itself could not tell "we could not read these lights"
    /// apart from "all of them do colour".
    func testColorCapabilityContextTakesCoverageFromThePassedSnapshot() {
        let card = liveCard("party")
        let effect = runningEffect(for: card)

        let partial = target(card: card,
                             color: CapabilityCoverage(supported: 1, total: 3,
                                                       evidence: .known))
        XCTAssertEqual(vm.colorCapabilityContext(for: effect, snapshot: partial).coverage,
                       partial.color)

        let unreadable = CustomizationSnapshotBuilder.unreadable(
            identity: identity(for: card), totalLights: 3,
            transport: .roomREST, running: true)
        let context = vm.colorCapabilityContext(for: effect, snapshot: unreadable)
        XCTAssertEqual(context.coverage, unreadable.color)
        XCTAssertEqual(context.coverage?.evidence, .unreadable,
                       "the evidence must survive — .known coverage on unread lights is the lie")
    }

    private func runningEffect(for card: StudioCard) -> RunningEffect {
        let room = RoomDisplayItem(
            kind: .room, id: "room-1", name: "Living Room", archetype: nil,
            isOn: true, brightness: 50, groupedLightID: "gl-1", lightCount: 3,
            bridgeID: "bridge-A",
            childResourceRefs: [(rid: "L1", rtype: "light"),
                                (rid: "L2", rtype: "light"),
                                (rid: "L3", rtype: "light")])
        return RunningEffect(cardID: card.id, card: card, room: room,
                             lightIDs: ["L1", "L2", "L3"],
                             isEntertainment: false, requestedTransport: nil,
                             transportFallback: false, identity: identity(for: card))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - 17. `.hidden` is reachable again (M6)
    // ──────────────────────────────────────────────────────────

    /// Descriptors used to leave `appliesToExecution` empty, which made the
    /// resolver's no-orphan check — and therefore its whole `.hidden` state —
    /// dead code. Every descriptor now claims its own card, so a control
    /// resolved against ANOTHER card's target hides instead of answering as
    /// if it were at home.
    func testDescriptorsClaimTheirOwnCardSoHiddenIsReachable() {
        let party = liveCard("party")
        let strobe = liveCard("strobe")
        let descriptor = StudioBoardAvailability.descriptor(card: strobe,
                                                            param: param(strobe, "duty_cycle"))
        XCTAssertEqual(descriptor?.appliesToExecution, ["strobe"])

        // Strobe's control measured against a target running PARTY.
        let foreign = CustomizationResolver.resolve(control: descriptor!,
                                                    on: target(card: party))
        XCTAssertEqual(foreign.availability, .hidden)
        XCTAssertFalse(foreign.availability.rendersControl)
    }

    /// …and the bridge-native side of the same rule.
    func testBridgeNativeDescriptorsClaimTheirOwnCard() {
        let card = effectCard("opal")
        let descriptor = StudioBoardAvailability.descriptor(card: card,
                                                            param: param(card, "speed"))
        XCTAssertEqual(descriptor?.appliesToExecution, ["opal"])
    }

    /// Nothing on screen changes: both renderers hand the funnel the card's
    /// own params against that card's own running row, so every shipping
    /// control still resolves to a real, rendering answer.
    func testNoShippingControlBecomesHidden() {
        for card in vm.liveModeCards + vm.effectCards {
            let snapshot = target(card: card, transport: .bridgeEffectV2)
            for p in card.params {
                guard let resolution = StudioBoardAvailability.resolve(
                    card: card, param: p, snapshot: snapshot) else { continue }
                XCTAssertNotEqual(resolution.availability, .hidden,
                                  "\(card.id).\(p.id) went hidden on its OWN target")
            }
        }
    }
}
