//
//  EffectParameterProfiles.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (audit §7 verified parameter
//  profiles for the bridge-native firmware effects).
//
//  The bridge exposes no machine-readable per-effect parameter schema, so the
//  audit requires a SMALL EXPLICIT TABLE of verified combinations, each backed
//  by evidence. This is that table. Every entry cites either the shipping
//  send path that proves the parameter reaches the bridge (code-proven), or
//  names the physical check still owed (hardware-pending). Nothing here is
//  guessed, and nothing absent from this table may render as an active
//  control for a bridge-native effect.
//
//  Evidence base (verified on this branch):
//
//  * `speed` — live per-light `effects_v2` re-parameterization exists ONLY
//    under v2 (`performBridgeSend`, speed case; start-time
//    `applyStudioEffectV2Parameters`). There is NO legacy send path — on a
//    v1-only room the parameter is genuinely unavailable, not slow.
//  * `base_color` / `warmth` — live per-light v2 paths exist; a grouped
//    xy/mirek light-state fallback also ships for v2-incapable lights.
//    The fallback is PRESERVED (it is long-shipping behavior), but whether a
//    grouped state write visibly fights an active firmware effect is a
//    hardware question — those combinations stay hardware-pending and the
//    fallback classifies as an approximation, never as full live mutation.
//  * `brightness` — a grouped light-state write (not an effect parameter).
//    The send is code-proven; whether it scales the running firmware effect's
//    output on every model is hardware-pending.
//  * `transition` (Smoothness) — sends NOTHING. It shapes the
//    `dynamics.duration` of subsequent brightness/warmth/color writes. Its
//    honest mutation classification is the new `.nextWrite`.
//
//  Prism and Color Loop declare no tint/warmth today; the audit's open
//  question ("do they have a meaningful verified capability?") remains
//  investigated-and-not-exposed — adding one requires hardware evidence, not
//  a request body that happens to encode it.
//

import Foundation

/// How a verified bridge-native parameter row is proven.
enum EffectParameterEvidence: Hashable, Sendable {
    /// The shipping send path proves the parameter reaches the bridge.
    /// The citation names the path.
    case codeProven(citation: String)
    /// The parameter can be sent, but its visible behavior on hardware is
    /// not yet validated. The note names the exact pending check.
    case hardwarePending(note: String)
}

/// One verified parameter on one firmware effect.
struct EffectParameterProfile: Hashable, Sendable {
    /// How a change lands while the effect is running.
    let liveBehavior: CustomizationMutationBehavior
    /// What the parameter needs from the target to be honest.
    let requirement: CapabilityRequirement
    /// Proof, or the exact hardware check owed.
    let evidence: EffectParameterEvidence
}

/// The audit-§7 table: effect name → paramID → verified profile.
enum EffectParameterProfiles {

    /// Shared rows — the five parameter shapes every bridge-native card
    /// composes from. Kept as builders so per-effect differences (which
    /// params a card declares) stay in the card catalog, and the PROOF for a
    /// given parameter shape lives exactly once.
    private static let speedProfile = EffectParameterProfile(
        liveBehavior: .debounced,
        requirement: .effectsV2,
        evidence: .codeProven(citation:
            "StudioViewModel+CustomizationWiring.performBridgeSend speed case — v2-only, no legacy branch"))

    private static let baseColorProfile = EffectParameterProfile(
        liveBehavior: .debounced,
        // Color capability is the honest gate: v2-capable lights get the
        // per-light effect tint; v1-only lights keep the PRESERVED grouped
        // xy fallback (an approximation, hardware-pending) — so the control
        // is not unavailable there, just not fully live.
        requirement: .color,
        evidence: .codeProven(citation:
            "performBridgeSend base_color case — per-light EffectsV2Body(colorXY:), grouped xy fallback"))

    /// The grouped-xy fallback for v2-incapable lights: preserved shipping
    /// behavior, classified as an approximation until hardware answers
    /// whether it fights the running firmware effect.
    private static let baseColorFallbackNote =
        "grouped xy write on v1-only lights while the firmware effect runs — verify it does not visibly fight the effect"

    private static let warmthProfile = EffectParameterProfile(
        liveBehavior: .debounced,
        // Same gate logic as base_color: CT capability decides; the v2-vs-
        // grouped difference is a transport note, not availability.
        requirement: .colorTemperature,
        evidence: .codeProven(citation:
            "performBridgeSend warmth case — per-light EffectsV2Body(mirek:), grouped mirek fallback"))

    private static let brightnessProfile = EffectParameterProfile(
        liveBehavior: .debounced,
        requirement: .dimming,
        evidence: .hardwarePending(note:
            "grouped light-state brightness during an active firmware effect — verify visible scaling per effect"))

    private static let transitionProfile = EffectParameterProfile(
        liveBehavior: .nextWrite,
        requirement: .none,
        evidence: .codeProven(citation:
            "performBridgeSend — transition sends nothing; it feeds dynamics.duration of later writes"))

    /// Which of the five shapes each effect's declared params map to. The
    /// catalog declares WHICH params exist; this proves WHAT each one does.
    static func profile(effect: String, paramID: String) -> EffectParameterProfile? {
        switch paramID {
        case "speed":      return speedProfile
        case "base_color": return baseColorProfile
        case "warmth":     return warmthProfile
        case "brightness": return brightnessProfile
        case "transition": return transitionProfile
        default:           return nil   // undeclared/unverified — never exposed
        }
    }

    /// The verified-parameter sets for `CustomizationTargetSnapshot`, per
    /// effect: parameters with a code-proven LIVE path. Hardware-pending rows
    /// are deliberately absent.
    ///
    /// WHAT THAT ABSENCE ACTUALLY DOES (corrected — the old comment here
    /// claimed a mechanism that does not exist):
    ///
    /// `verifiedEffectParameters` is read by exactly one requirement shape,
    /// `.effectParameter(effect:parameter:)`, and NONE of the five profiles
    /// above uses it — each states the hardware fact it really needs
    /// (`.effectsV2`, `.color`, `.colorTemperature`, `.dimming`, `.none`),
    /// because "we have not physically watched this parameter work" is not a
    /// reason to take a shipping control away from the user.
    ///
    /// So this set does not gate availability. What carries the pending check
    /// to the screen is `StudioBoardResolution.isHardwareUnverified`: the
    /// board funnel reads `profile.evidence` (plus the v1-only grouped-fallback
    /// case for `base_color`/`warmth`) and renders such a control EDITABLE but
    /// quieted, with "UNVERIFIED ON THESE LIGHTS" — never as fully live. This
    /// set stays the machine-readable inventory of what is code-proven, which
    /// is what the capability matrix and `pendingHardwareChecks` are generated
    /// against.
    static func verifiedLiveParameters(for effect: String,
                                       declaredParamIDs: [String]) -> Set<String> {
        Set(declaredParamIDs.filter { id in
            guard let p = profile(effect: effect, paramID: id) else { return false }
            if case .codeProven = p.evidence { return true }
            return false
        })
    }

    /// Every hardware check this table still owes, for the on-device
    /// checklist. Deterministic order.
    ///
    /// SHAPE LOCK: `Scripts/generate_capability_matrix.py` parses this literal
    /// with a regex that expects `("paramID", …)` rows inside a `[ … ]`, so the
    /// tuple shape is load-bearing beyond Swift. Scope lives in
    /// `groupedFallbackOnlyChecks` beside it rather than as a third tuple
    /// element for exactly that reason.
    static var pendingHardwareChecks: [(paramID: String, note: String)] {
        [
            ("brightness", "grouped light-state brightness during an active firmware effect — verify visible scaling per effect"),
            ("base_color", baseColorFallbackNote),
            ("warmth", "grouped mirek write on v1-only lights while the firmware effect runs — verify it does not visibly fight the effect"),
            ("speed", "visible firmware response to live effects_v2 speed per effect and light model"),
        ]
    }

    /// The paramIDs above, as a set — the SINGLE SOURCE OF TRUTH for "does
    /// this parameter still owe a hardware check?".
    ///
    /// `StudioBoardAvailability` used to carry its own parallel list, which
    /// drifted: it labelled `brightness` (via `.hardwarePending` evidence) and
    /// the `base_color`/`warmth` grouped fallback, but silently omitted
    /// `speed` — a check this table has owed all along, and the one control
    /// that is the HERO knob on every bridge-native board.
    static var pendingHardwareCheckParamIDs: Set<String> {
        Set(pendingHardwareChecks.map(\.paramID))
    }

    /// Pending checks owed ONLY where the v1-only grouped light-state write
    /// stands in for the per-light `effects_v2` path.
    ///
    /// These two ship a code-proven per-light v2 write — on a room whose
    /// lights took `effects_v2` there is nothing left to verify. It is the
    /// PRESERVED grouped xy/mirek fallback, used when the lights refused v2,
    /// whose behaviour against a running firmware effect nobody has watched.
    /// Every other pending check (`brightness`, `speed`) is owed everywhere.
    ///
    /// A subset of `pendingHardwareCheckParamIDs` by construction —
    /// `StudioBoardAvailabilityTests` pins that the two agree.
    static let groupedFallbackOnlyChecks: Set<String> = ["base_color", "warmth"]
}
