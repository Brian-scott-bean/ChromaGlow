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
                        colorTemperature: CapabilityCoverage? = nil,
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
                       "CHECKING WHAT THESE LIGHTS SUPPORT — REFRESHES WHEN THE BRIDGE ANSWERS",
                       "the note must say what happens next, not name a dead end")
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
        XCTAssertEqual(StudioBoardAvailability.opacity(resolution: resolution,
                                                       strategy: card.strategy),
                       StudioBoardAvailability.stagedOpacity,
                       "unproven must not LOOK like proven")
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
}
