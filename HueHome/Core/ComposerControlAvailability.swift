//
//  ComposerControlAvailability.swift
//  HueHome
//
//  Unified Customization Engine — Slice 3 (Composer convergence, S3-4).
//
//  THE DEFECT THIS CLOSES
//  ──────────────────────
//  The Composer answered "may the user touch this?" with a single boolean,
//  `roomHasColorLights`, that defaulted to TRUE, was written once per apply
//  from a whole-room light scan, and lived on the view model as one global
//  slot shared by every running composition. Every other Composer control
//  had no answer at all: Warmth rendered a fixed 153…500 range on lights
//  that could not honour it, the hue pad rendered fully live on an unread
//  room, and "we have not read these lights yet" was indistinguishable from
//  "all of them do colour".
//
//  This is the Composer's ADAPTER into the one availability funnel. It is a
//  sibling of `StudioBoardAvailability`, not a replacement and not a
//  flattening: Composer controls are typed fields on four config structs,
//  and they stay that way (spec §20 — Composer is never a `StudioParam`).
//  What the adapter does is name each control with the catalog's string id
//  (`ComposerControlCatalog`), give it the `CapabilityRequirement` its write
//  genuinely depends on, and hand it to the SAME pure resolver, snapshot and
//  copy every board control goes through. Same states (Active / Partial /
//  Staged / Unavailable / Hidden), same rule that unknown is never
//  unsupported, same words on screen.
//
//  NIL NEVER MEANS YES. `StudioBoardAvailability.descriptor(.composition)`
//  returns nil and its strategy-qualified overloads fail OPEN for
//  compositions ("not this funnel's business"). This adapter always produces
//  a resolution, so the Composer views call the non-optional overloads —
//  `isInteractive(_:)`, `opacity(_:)`, `note(for:isColor:)` — and the
//  nil-tolerant wrappers below fail CLOSED: no snapshot means CHECKING and
//  not interactive, never a live control standing on nothing.
//
//  Pure: no SwiftUI, no networking, no I/O.
//

import Foundation

enum ComposerControlAvailability {

    // ── Requirements ────────────────────────────────────────────

    /// Controls whose write lands in `PaletteConfig` colour fields. Useless —
    /// and dishonest as a live control — without a colour-capable light.
    static let colorControlIDs: Set<String> = [
        "colorPad", "harmony", "color1", "color2", "color3",
        "hueShift", "saturation", "randomize", "dynamicSceneExport",
        // The `.color` option of the reaction Targets chips: modulating a
        // colour that no light renders is a dead toggle.
        "targetColor",
    ]

    /// Controls whose write is a mirek value: the Warmth control in
    /// temperature mode. Requires a CT-capable light AND a readable range —
    /// `CapabilityRequirement.colorTemperature` answers `.unknown` without
    /// the range, so a schemaless fixture reads CHECKING, never a fake clamp.
    static let colorTemperatureControlIDs: Set<String> = ["temperature"]

    /// The hardware precondition for one catalog control id.
    ///
    /// Everything not listed above is `.none`: motion, envelope and reaction
    /// numerics drive the composition engine, which renders on whatever the
    /// target can do (dimming is universal on Hue — `StudioBoardAvailability`
    /// deliberately never requires it either). Spatial motion keeps its own
    /// gate — Entertainment-area MEMBERSHIP, answered per target by the view —
    /// because `forward`/`mirror` are meaningful on REST index positions and
    /// requiring streaming for them would refuse a control that works.
    static func requirement(for controlID: String) -> CapabilityRequirement {
        if colorControlIDs.contains(controlID) { return .color }
        if colorTemperatureControlIDs.contains(controlID) { return .colorTemperature }
        return .none
    }

    /// The resolver descriptor: this control, on this card and no other
    /// (so the resolver's orphan check — and its `.hidden` state — is live),
    /// `.immediate` while running (the render loop reads the box every
    /// frame), `.staged` when idle.
    static func descriptor(cardID: String, controlID: String) -> CustomizationControlDescriptor {
        CustomizationControlDescriptor(
            id: CustomizationControlID(cardID: cardID, paramID: controlID),
            requirement: requirement(for: controlID),
            liveBehavior: .immediate,
            idleBehavior: .staged,
            appliesToExecution: [cardID])
    }

    // ── Resolution ──────────────────────────────────────────────

    /// The funnel's answer for one Composer control on one target. Always a
    /// resolution — the Composer has no "not resolver-governed" controls.
    ///
    /// `isHardwareUnverified` is false by construction: the Composer's send
    /// path is the app-driven composition engine, not a bridge-native
    /// firmware parameter, so there is no audit-§7 profile row to be pending.
    static func resolve(cardID: String,
                        controlID: String,
                        snapshot: CustomizationTargetSnapshot) -> StudioBoardResolution {
        let resolved = CustomizationResolver.resolve(
            control: descriptor(cardID: cardID, controlID: controlID), on: snapshot)
        return StudioBoardResolution(resolution: resolved,
                                     isHardwareUnverified: false,
                                     totalLights: snapshot.totalLights)
    }

    // ── Nil-tolerant presentation (FAIL CLOSED) ─────────────────

    /// Interactive only on a real resolution the funnel calls interactive.
    /// No snapshot (nothing running, or the target could not be identified)
    /// is NOT a licence to render a live control.
    static func isInteractive(_ resolution: StudioBoardResolution?) -> Bool {
        guard let resolution else { return false }
        return StudioBoardAvailability.isInteractive(resolution.availability)
    }

    static func opacity(_ resolution: StudioBoardResolution?) -> Double {
        guard let resolution else { return StudioBoardAvailability.disabledOpacity }
        return StudioBoardAvailability.opacity(resolution.availability)
    }

    /// Renders unless the funnel says `.hidden` (an orphaned control id).
    /// A nil resolution renders — disabled and captioned CHECKING — because
    /// a control that vanishes while the bridge is still being asked is the
    /// silent-removal the honesty rule forbids.
    static func rendersControl(_ resolution: StudioBoardResolution?) -> Bool {
        StudioBoardAvailability.rendersControl(resolution)
    }

    /// The caption beside a not-fully-live control — the board's own words.
    static func note(for resolution: StudioBoardResolution?, isColor: Bool) -> String? {
        guard let resolution else { return StudioBoardAvailability.checkingCopy }
        return StudioBoardAvailability.note(for: resolution, isColor: isColor)
    }

    // ── Warmth range (checklist §V-B row 58, Composer half) ─────

    /// The mirek range the Warmth control may author: the snapshot's
    /// INTERSECTED range across the target's CT-capable lights. Nil when the
    /// target has no readable range — in which case `temperature` resolves
    /// `.unavailable` (CHECKING) and the control is disabled, so the value
    /// the disabled control displays is never presented as authorable.
    static func warmthRange(snapshot: CustomizationTargetSnapshot?) -> ClosedRange<Double>? {
        guard let range = snapshot?.mirekRange else { return nil }
        return Double(range.minMirek)...Double(range.maxMirek)
    }

    /// Display-only travel for a DISABLED Warmth control with no readable
    /// range: the full Hue CT span, so the stored value has somewhere to sit.
    /// Never the authoring range of an interactive control.
    static let fallbackWarmthRange: ClosedRange<Double> = 153...500
}
