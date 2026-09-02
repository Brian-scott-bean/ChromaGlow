//
//  ComposerControlAvailabilityTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 3 (Composer convergence, S3-4).
//
//  The Composer used to answer "may the user touch this?" with one boolean
//  that defaulted to yes. These tests are the proof that every Composer
//  control now answers through the SAME pure resolver the Studio board uses,
//  against the same snapshot shape, with the same five states and the same
//  words — and that unknown never reads as unsupported.
//
//  Pure: no network, no clock, no sleeps.
//

import XCTest
@testable import HueHome

final class ComposerControlAvailabilityTests: XCTestCase {

    private let cardID = "comp_00000000-0000-0000-0000-000000000001"

    private func identity(cardID: String? = nil) -> RunningLookIdentity {
        RunningLookIdentity(bridgeID: "bridge-A", groupID: "room-1", kind: .room,
                            cardID: cardID ?? self.cardID,
                            execution: .composition(presetID: UUID()),
                            generation: CustomizationGeneration(1))
    }

    private func target(lights: Int = 3,
                        color: CapabilityCoverage? = nil,
                        colorTemperature: CapabilityCoverage? = nil,
                        mirekRange: MirekRange? = MirekRange(minMirek: 153, maxMirek: 500),
                        transport: CustomizationTransport = .roomREST,
                        running: Bool = true,
                        cardID: String? = nil) -> CustomizationTargetSnapshot {
        CustomizationTargetSnapshot(
            identity: identity(cardID: cardID),
            totalLights: lights,
            reachableLights: lights,
            dimming: .all(total: lights),
            color: color ?? .all(total: lights),
            colorTemperature: colorTemperature ?? .all(total: lights),
            mirekRange: mirekRange,
            gradient: .none(total: lights),
            effectsV2: .none(total: lights),
            entertainmentAvailable: .unknown,
            transport: transport,
            running: running)
    }

    private func unreadable(lights: Int = 3) -> CustomizationTargetSnapshot {
        CustomizationSnapshotBuilder.unreadable(identity: identity(), totalLights: lights,
                                                transport: .roomREST, running: true)
    }

    private func resolve(_ controlID: String, on snapshot: CustomizationTargetSnapshot,
                         cardID: String? = nil) -> StudioBoardResolution {
        ComposerControlAvailability.resolve(cardID: cardID ?? self.cardID,
                                            controlID: controlID, snapshot: snapshot)
    }

    // ── Requirement table ───────────────────────────────────────

    /// The catalog's colour-writing controls need colour; Warmth needs CT;
    /// nothing else has a hardware precondition. Enumerated so a control
    /// added to the catalog without a row here is a visible decision.
    func testRequirementTableCoversTheCatalog() {
        let colour: Set<String> = ["colorPad", "harmony", "color1", "color2", "color3",
                                   "hueShift", "saturation", "randomize",
                                   "dynamicSceneExport", "targetColor"]
        for id in colour {
            XCTAssertEqual(ComposerControlAvailability.requirement(for: id), .color, id)
        }
        XCTAssertEqual(ComposerControlAvailability.requirement(for: "temperature"), .colorTemperature)

        // Every id the catalog can render, across every gating state, has an
        // explicit answer — and the non-colour ones are `.none`.
        var seen = Set<String>()
        for tab in CompositionLayerTab.allCases {
            for mode in PaletteConfig.Mode.allCases {
                for pattern in MotionConfig.Pattern.allCases {
                    for shape in EnvelopeConfig.Shape.allCases {
                        for source in ReactionConfig.Source.allCases {
                            seen.formUnion(ComposerControlCatalog.renderedControlIDs(
                                tab: tab, paletteMode: mode, motionPattern: pattern,
                                envelopeShape: shape, reactionSource: source))
                        }
                    }
                }
            }
        }
        XCTAssertFalse(seen.isEmpty)
        for id in seen where !colour.contains(id) && id != "temperature" {
            XCTAssertEqual(ComposerControlAvailability.requirement(for: id), .none,
                           "\(id) grew a hardware requirement the catalog does not document")
        }
        // Motion, envelope and reaction numerics drive the engine on any Hue
        // light — never colour-gated (a white-only room still breathes).
        for id in ["speed", "spread", "offset", "bpm", "depth", "attack", "decay",
                   "dutyCycle", "minBrightness", "maxBrightness", "sensitivity",
                   "smoothing", "threshold", "intensity", "pattern", "shape", "source",
                   "targets", "mode", "direction", "forward", "mirror"] {
            XCTAssertEqual(ComposerControlAvailability.requirement(for: id), .none, id)
        }
    }

    // ── The five states, on colour ──────────────────────────────

    func testSupportedColourIsActiveAndInteractive() {
        let r = resolve("colorPad", on: target())
        XCTAssertEqual(r.availability, .active)
        XCTAssertEqual(r.behavior, .immediate, "the render loop reads the box every frame")
        XCTAssertTrue(ComposerControlAvailability.isInteractive(r))
        XCTAssertEqual(ComposerControlAvailability.opacity(r), 1)
        XCTAssertNil(ComposerControlAvailability.note(for: r, isColor: true))
        XCTAssertTrue(ComposerControlAvailability.rendersControl(r))
    }

    func testPartialColourIsInteractiveAndStatesItsCoverage() {
        let r = resolve("hueShift", on: target(color: CapabilityCoverage(supported: 2, total: 3, evidence: .known)))
        XCTAssertEqual(r.availability, .partial(supported: 2, total: 3, reason: .partialHardwareCoverage))
        XCTAssertTrue(ComposerControlAvailability.isInteractive(r))
        XCTAssertEqual(ComposerControlAvailability.opacity(r), 1)
        XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: false), "2 OF 3 LIGHTS RESPOND")
        // The pad badges its own count — the caption does not say it twice.
        XCTAssertNil(ComposerControlAvailability.note(for: r, isColor: true))
    }

    /// Known-no: RENDERED, disabled, with truthful refusal copy — never
    /// silently removed.
    func testKnownUnsupportedColourIsRenderedDisabledWithRefusalCopy() {
        let r = resolve("harmony", on: target(color: .none(total: 3)))
        XCTAssertEqual(r.availability, .unavailable(reason: .noColorCapableLights,
                                                    remediation: .addCapableLights))
        XCTAssertTrue(ComposerControlAvailability.rendersControl(r), "unsupported is disabled, not hidden")
        XCTAssertFalse(ComposerControlAvailability.isInteractive(r))
        XCTAssertEqual(ComposerControlAvailability.opacity(r), StudioBoardAvailability.disabledOpacity)
        XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: true), "NO COLOR LIGHTS HERE")
    }

    /// THE honesty rule: unknown is not unsupported. An unread target reads
    /// CHECKING, disabled, with a retry — never a refusal.
    func testUnreadableTargetReadsCheckingNeverUnsupported() {
        for id in ["colorPad", "harmony", "temperature", "randomize", "targetColor"] {
            let r = resolve(id, on: unreadable())
            guard case .unavailable(let reason, let remediation) = r.availability else {
                return XCTFail("\(id): \(r.availability)")
            }
            XCTAssertEqual(reason, .capabilityUnknown, id)
            XCTAssertEqual(remediation, .retryCapabilityFetch, id)
            XCTAssertFalse(ComposerControlAvailability.isInteractive(r), id)
            XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: false),
                           StudioBoardAvailability.checkingCopy, id)
            XCTAssertTrue(ComposerControlAvailability.rendersControl(r), id)
        }
    }

    /// …while the controls with no hardware precondition stay LIVE on the
    /// same unread target — a white-only or unread room still breathes.
    func testHardwareFreeControlsStayActiveOnAnUnreadOrColourlessTarget() {
        for snapshot in [unreadable(), target(color: .none(total: 3))] {
            for id in ["speed", "bpm", "depth", "pattern", "shape", "source", "targets",
                       "intensity", "maxBrightness", "spread", "mirror", "forward"] {
                let r = resolve(id, on: snapshot)
                XCTAssertEqual(r.availability, .active, id)
                XCTAssertTrue(ComposerControlAvailability.isInteractive(r), id)
                XCTAssertNil(ComposerControlAvailability.note(for: r, isColor: false), id)
            }
        }
    }

    /// Hidden only where the resolver's own rule calls for it: a control id
    /// resolved against a DIFFERENT card's target is an orphan.
    func testOrphanedControlIsHiddenAndRendersNothing() {
        let r = resolve("speed", on: target(cardID: "comp_other"))
        XCTAssertEqual(r.availability, .hidden)
        XCTAssertFalse(ComposerControlAvailability.rendersControl(r))
        XCTAssertFalse(ComposerControlAvailability.isInteractive(r))
        // …and a capability answer is NEVER hidden.
        XCTAssertNotEqual(resolve("colorPad", on: target(color: .none(total: 3))).availability, .hidden)
        XCTAssertNotEqual(resolve("colorPad", on: unreadable()).availability, .hidden)
    }

    /// Idle (not running) is staged — editable, saved, honest about not being
    /// live — not active.
    func testIdleTargetIsStagedNotActive() {
        let r = resolve("colorPad", on: target(running: false))
        XCTAssertEqual(r.availability, .staged(reason: .notRunning, remediation: .startTheLook))
        XCTAssertTrue(ComposerControlAvailability.isInteractive(r))
        XCTAssertEqual(ComposerControlAvailability.opacity(r), StudioBoardAvailability.stagedOpacity)
        XCTAssertEqual(r.behavior, .staged)
    }

    /// Zero lights outranks everything.
    func testAnEmptyTargetSaysNoLightsHere() {
        let r = resolve("speed", on: target(lights: 0))
        XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: false), "NO LIGHTS HERE")
    }

    // ── Nil fails closed ────────────────────────────────────────

    func testNilResolutionFailsClosedAsChecking() {
        XCTAssertFalse(ComposerControlAvailability.isInteractive(nil))
        XCTAssertEqual(ComposerControlAvailability.opacity(nil), StudioBoardAvailability.disabledOpacity)
        XCTAssertEqual(ComposerControlAvailability.note(for: nil, isColor: false),
                       StudioBoardAvailability.checkingCopy)
        XCTAssertTrue(ComposerControlAvailability.rendersControl(nil),
                      "a control that vanishes while we are still asking is the silent removal the rule forbids")
    }

    // ── Warmth (checklist row 58, Composer half) ────────────────

    func testWarmthAuthorsTheSnapshotsIntersectedRange() {
        let narrow = target(mirekRange: MirekRange(minMirek: 200, maxMirek: 400))
        XCTAssertEqual(ComposerControlAvailability.warmthRange(snapshot: narrow), 200...400)
        XCTAssertEqual(resolve("temperature", on: narrow).availability, .active)
    }

    func testWarmthWithoutAReadableRangeIsCheckingAndAuthorsNoRange() {
        let schemaless = target(mirekRange: nil)
        XCTAssertNil(ComposerControlAvailability.warmthRange(snapshot: schemaless),
                     "no readable range → no authoring range, never a fake 153…500")
        let r = resolve("temperature", on: schemaless)
        guard case .unavailable(let reason, _) = r.availability else { return XCTFail("\(r.availability)") }
        XCTAssertEqual(reason, .capabilityUnknown)
        XCTAssertFalse(ComposerControlAvailability.isInteractive(r))
        XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: false),
                       StudioBoardAvailability.checkingCopy)
        XCTAssertNil(ComposerControlAvailability.warmthRange(snapshot: nil))
    }

    func testWarmthOnLightsWithoutCTIsRefusedInWords() {
        let r = resolve("temperature", on: target(colorTemperature: .none(total: 3), mirekRange: nil))
        XCTAssertEqual(r.availability, .unavailable(reason: .noCTCapableLights,
                                                    remediation: .addCapableLights))
        XCTAssertEqual(ComposerControlAvailability.note(for: r, isColor: false), "NO WHITE-TONE LIGHTS HERE")
        XCTAssertFalse(ComposerControlAvailability.isInteractive(r))
    }

    // ── Reaction targets ────────────────────────────────────────

    /// The `.color` target needs colour; brightness/speed do not.
    func testColourTargetIsGatedWhileTheOthersAreNot() {
        let colourless = target(color: .none(total: 3))
        XCTAssertFalse(ComposerControlAvailability.isInteractive(resolve("targetColor", on: colourless)))
        XCTAssertTrue(ComposerControlAvailability.isInteractive(resolve("targets", on: colourless)))
    }

    // ── Descriptor shape ────────────────────────────────────────

    func testDescriptorBelongsToItsCardOnly() {
        let d = ComposerControlAvailability.descriptor(cardID: cardID, controlID: "colorPad")
        XCTAssertEqual(d.id, CustomizationControlID(cardID: cardID, paramID: "colorPad"))
        XCTAssertEqual(d.appliesToExecution, [cardID])
        XCTAssertEqual(d.liveBehavior, .immediate)
        XCTAssertEqual(d.idleBehavior, .staged)
        // Never a hardware-pending caveat: the Composer has no firmware
        // parameter row to owe a check on.
        XCTAssertFalse(resolve("colorPad", on: target()).isHardwareUnverified)
    }
}
