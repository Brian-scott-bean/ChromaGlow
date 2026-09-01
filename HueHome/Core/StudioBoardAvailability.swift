//
//  StudioBoardAvailability.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 remediation R2 (one resolver truth
//  path for the board).
//
//  THE DEFECT THIS CLOSES
//  ──────────────────────
//  `StudioBoardView` had three different answers to "may the user touch this
//  control?":
//
//    * bridge-native params went through `EffectParameterProfiles` and the
//      resolver;
//    * every app-driven (Live-card) param returned nil from the view's local
//      `resolution(for:)` — nil meant "interactive", so a colour picker on a
//      colourless room, or Strobe's flash colour while the look ran over REST,
//      rendered fully live and silently did nothing;
//    * the colour section bypassed the resolver entirely and consulted a
//      separately-built `ColorCapabilityContext`.
//
//  This type is the single funnel. Every control on the board — numeric or
//  colour, bridge-native or app-driven — asks exactly these four questions,
//  and the answers are pure, deterministic and unit-testable without a bridge.
//
//  WHY `entOnly` BECOMES A REQUIREMENT
//  ───────────────────────────────────
//  `StudioParam.entOnly` is the one-bit ancestor of `CapabilityRequirement`
//  (see `CustomizationCapability.swift`). Translating it here — rather than
//  branching on it in a view body — is what completes the audit-§17 migration
//  `entOnly` → `.transport(.entertainment)`: the flag stays as catalog
//  metadata, but the *decision* is made once, by the resolver.
//
//  A colour picker that is ALSO streaming-only carries both requirements
//  (`.all([.color, .transport(.entertainment)])`). Order matters for honesty:
//  `combineAll` lets one hard hardware "no" end the evaluation, so a room with
//  no colour lights says "NO COLOR LIGHTS HERE" instead of the softer, and in
//  that room wrong, "turn streaming on".
//
//  Pure: no SwiftUI, no networking, no I/O.
//

import Foundation

enum StudioBoardAvailability {

    /// Reduced-but-editable opacity for a `.staged` control — spec §17's
    /// staged state is "editable and saved, not affecting current output",
    /// so it must look quieter without ever looking disabled.
    static let stagedOpacity: Double = 0.7
    /// A control the user genuinely may not touch.
    static let disabledOpacity: Double = 0.45

    // ── Descriptors ─────────────────────────────────────────────

    /// The resolver descriptor for one control on one card, or nil when this
    /// card's controls are not resolver-governed.
    ///
    /// * **bridge-native** — the audit-§7 verified profile table decides. A
    ///   parameter absent from that table has no proven send path and stays
    ///   nil (unchanged shipping behaviour).
    /// * **app-driven** — colour pickers require colour; `entOnly` params
    ///   require the Entertainment transport; everything else has no hardware
    ///   precondition. Engine loops read their param box every frame, so the
    ///   live behaviour is `.immediate`.
    /// * **composition** — nil. Composition boards are Composer-owned and
    ///   declare no board params here.
    static func descriptor(card: StudioCard,
                           param: StudioParam) -> CustomizationControlDescriptor? {
        let id = CustomizationControlID(cardID: card.id, paramID: param.id)
        switch card.strategy {
        case .bridgeNative(let effectName):
            guard let profile = EffectParameterProfiles.profile(effect: effectName,
                                                                paramID: param.id) else {
                return nil
            }
            return CustomizationControlDescriptor(id: id,
                                                  requirement: profile.requirement,
                                                  liveBehavior: profile.liveBehavior)

        case .appDriven:
            return CustomizationControlDescriptor(id: id,
                                                  requirement: requirement(for: param),
                                                  liveBehavior: .immediate,
                                                  idleBehavior: .staged)

        case .composition:
            return nil
        }
    }

    /// The app-driven requirement for one declared param.
    private static func requirement(for param: StudioParam) -> CapabilityRequirement {
        let transportRequirements: [CapabilityRequirement] =
            param.entOnly ? [.transport(.entertainment)] : []
        switch param.kind {
        case .colorPicker:
            // Hardware first: `combineAll` ends on the first hard "no", so a
            // colourless room never gets told to enable streaming.
            return .all([.color] + transportRequirements)
        case .slider, .toggle, .segmented:
            return transportRequirements.first ?? .none
        }
    }

    // ── Resolution ──────────────────────────────────────────────

    /// The resolver's answer for one control on one target, or nil when the
    /// control is not resolver-governed (composition boards, and bridge-native
    /// params with no verified profile).
    static func resolve(card: StudioCard,
                        param: StudioParam,
                        snapshot: CustomizationTargetSnapshot) -> CustomizationResolution? {
        guard let descriptor = descriptor(card: card, param: param) else { return nil }
        return CustomizationResolver.resolve(control: descriptor, on: snapshot)
    }

    // ── Interactivity (spec §17) ────────────────────────────────

    /// `.active`, `.partial` and `.staged` are all editable; `.unavailable`
    /// and `.hidden` are not.
    ///
    /// Staged being editable is the spec's own definition — "editable and
    /// saved, but intentionally not affecting current output". Disabling it
    /// (which the old `boardControl` did) threw the user's value away instead
    /// of holding it for the moment the transport arrives.
    static func isInteractive(_ availability: CustomizationAvailability) -> Bool {
        switch availability {
        case .active, .partial, .staged:  return true
        case .unavailable, .hidden:       return false
        }
    }

    /// Presentation opacity for a resolved control. Nil resolutions render at
    /// full strength (unchanged).
    static func opacity(_ availability: CustomizationAvailability) -> Double {
        switch availability {
        case .active, .partial:       return 1
        case .staged:                 return stagedOpacity
        case .unavailable, .hidden:   return disabledOpacity
        }
    }

    // ── Copy ────────────────────────────────────────────────────

    /// Human copy for a not-fully-live control — no API jargon, one note per
    /// control.
    ///
    /// `isColor` suppresses the partial-coverage line: the inline colour
    /// editor already badges "n OF m LIGHTS" beside its own chip, and saying
    /// it twice reads as two different problems.
    static func note(for resolution: CustomizationResolution,
                     isColor: Bool) -> String? {
        switch resolution.availability {
        case .active, .hidden:
            return nil

        case .partial(let supported, let total, _):
            return isColor ? nil : "\(supported) OF \(total) LIGHTS RESPOND"

        case .staged(let reason, _):
            // The transport-shaped stage is the one the user can act on, so
            // it gets its own words; every other staged reason keeps the
            // existing generic copy.
            return reason == .requiresEntertainment
                ? "STREAMING ONLY — INACTIVE IN ROOM MODE"
                : "SAVED — APPLIES WHEN SUPPORT ARRIVES"

        case .unavailable(let reason, _):
            switch reason {
            case .effectsV2Unavailable:
                return "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING"
            case .noCTCapableLights:
                return "NO WHITE-TONE LIGHTS HERE"
            case .noColorCapableLights:
                return "NO COLOR LIGHTS HERE"
            case .capabilityUnknown, .capabilityUnreadable:
                return "CHECKING WHAT THESE LIGHTS SUPPORT"
            default:
                return "NOT AVAILABLE FOR THESE LIGHTS"
            }
        }
    }
}
