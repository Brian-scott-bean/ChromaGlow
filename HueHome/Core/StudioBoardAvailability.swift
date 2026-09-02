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
//  WHAT THE FUNNEL CARRIES BEYOND THE RESOLVER
//  ───────────────────────────────────────────
//  Two facts the pure resolver has no vocabulary for, and whose loss the
//  adversarial review of the first cut caught:
//
//    * EVIDENCE. `EffectParameterProfiles` knows which bridge-native sends are
//      code-proven and which still owe a hardware check. Dropping that made a
//      hardware-pending parameter render as fully live with no note — the one
//      thing the capability matrix says must never happen. `StudioBoardResolution`
//      carries it, and such a control stays EDITABLE (the send works) while
//      saying "UNVERIFIED ON THESE LIGHTS".
//    * LIGHT COUNT. "We are still asking the bridge" and "there is nothing here
//      to ask about" are different truths, and only the snapshot can tell them
//      apart.
//
//  Pure: no SwiftUI, no networking, no I/O.
//

import Foundation

// ──────────────────────────────────────────────────────────────
// MARK: - The funnel's answer
// ──────────────────────────────────────────────────────────────

/// Everything the board needs to render ONE control honestly.
///
/// `CustomizationResolution` answers spec §17's two questions — may the user
/// touch this, and how does a change land. It has no vocabulary for a third
/// one the audit insists on: *do we actually KNOW this works on these lights?*
/// `EffectParameterProfiles` carries that evidence (`.hardwarePending`, and
/// the grouped-state fallback it calls an approximation), and the first cut of
/// this funnel dropped it on the floor — so a hardware-pending parameter such
/// as `brightness`, or `base_color` standing on the v1 grouped fallback,
/// rendered as a fully live control with no note at all. That is precisely the
/// "must not render as fully live" the capability matrix forbids.
///
/// Carrying the evidence through the funnel keeps the shipping control
/// EDITABLE — nothing here disables a send path that works — while making the
/// board say the one true thing it was hiding.
struct StudioBoardResolution: Hashable, Sendable {

    /// The pure resolver's verdict.
    let resolution: CustomizationResolution

    /// The send path exists and the resolver is satisfied, but its VISIBLE
    /// behaviour on these particular lights is not proven yet: an
    /// `EffectParameterProfiles` `.hardwarePending` row, or the grouped
    /// light-state approximation that stands in for the per-light `effects_v2`
    /// path on a v1-only room.
    let isHardwareUnverified: Bool

    /// Lights in the target. "There are none" is a different truth from "we
    /// are still asking", and only the snapshot knows which one it is.
    let totalLights: Int

    var availability: CustomizationAvailability { resolution.availability }
    var behavior: CustomizationMutationBehavior { resolution.behavior }
    var control: CustomizationControlID { resolution.control }
}

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
    /// * **app-driven** — colour pickers require colour; mirek sliders require
    ///   a CT-capable light; `entOnly` params require the Entertainment
    ///   transport; everything else has no hardware precondition. Engine loops read their param box every frame, so the
    ///   live behaviour is `.immediate`.
    /// * **composition** — nil. Composition boards are Composer-owned and
    ///   declare no board params here.
    static func descriptor(card: StudioCard,
                           param: StudioParam) -> CustomizationControlDescriptor? {
        let id = CustomizationControlID(cardID: card.id, paramID: param.id)
        // The control belongs to THIS card and no other. Descriptors used to
        // leave `appliesToExecution` empty, which made the resolver's
        // no-orphan check (and therefore its entire `.hidden` state) dead
        // code: a control resolved against another card's target answered as
        // if it were at home. Both renderers hand the funnel the card's own
        // params against that card's own running row, so nothing on screen
        // changes — but the check is now live, and `.hidden` is reachable.
        let ownCard: Set<String> = [card.id]
        switch card.strategy {
        case .bridgeNative(let effectName):
            guard let profile = EffectParameterProfiles.profile(effect: effectName,
                                                                paramID: param.id) else {
                return nil
            }
            return CustomizationControlDescriptor(id: id,
                                                  requirement: profile.requirement,
                                                  liveBehavior: profile.liveBehavior,
                                                  appliesToExecution: ownCard)

        case .appDriven:
            return CustomizationControlDescriptor(id: id,
                                                  requirement: requirement(for: param),
                                                  liveBehavior: .immediate,
                                                  idleBehavior: .staged,
                                                  appliesToExecution: ownCard)

        case .composition:
            return nil
        }
    }

    /// Numeric app-driven params that are colour-temperature controls in
    /// disguise. Their catalog kind is `.slider` (a mirek range), so `kind`
    /// alone cannot tell them apart from Speed — and without this map
    /// `ambient.warmth` resolved `.active` on a room with no CT-capable
    /// light at all, writing mirek into fixtures that cannot honour it.
    ///
    /// `brightness`/`min_brightness` deliberately stay out: dimming is
    /// universal on Hue, so requiring it would add a caveat nobody needs.
    private static let colorTemperatureParamIDs: Set<String> = ["warmth"]

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
            if colorTemperatureParamIDs.contains(param.id) {
                // Same ordering rule as colour: the hardware "no" must win, so
                // a room without CT lights hears about its lights, not about
                // streaming.
                return .all([.colorTemperature] + transportRequirements)
            }
            return transportRequirements.first ?? .none
        }
    }

    // ── Resolution ──────────────────────────────────────────────

    /// The funnel's answer for one control on one target, or nil when the
    /// control is not resolver-governed (composition boards, and bridge-native
    /// params with no verified profile).
    ///
    /// Nil is NOT "yes" — see `isInteractive(resolution:strategy:)`.
    static func resolve(card: StudioCard,
                        param: StudioParam,
                        snapshot: CustomizationTargetSnapshot) -> StudioBoardResolution? {
        guard let descriptor = descriptor(card: card, param: param) else { return nil }
        let resolved = CustomizationResolver.resolve(control: descriptor, on: snapshot)
        let resolution = narrowedToEffectsV2Coverage(resolved, card: card,
                                                     param: param, snapshot: snapshot)
        return StudioBoardResolution(
            resolution: resolution,
            isHardwareUnverified: isHardwareUnverified(card: card,
                                                       param: param,
                                                       snapshot: snapshot,
                                                       availability: resolution.availability),
            totalLights: snapshot.totalLights)
    }

    /// Bridge-native params whose live send is the PER-LIGHT `effects_v2`
    /// write — so their real reach is the v2-capable subset of the room, not
    /// the room.
    ///
    /// THE DEFECT THIS CLOSES. `performBridgeSend` issues the per-light v2
    /// body only for the ids that took `effects_v2`; the rest of the room gets
    /// nothing from these three. But `targetSnapshot(for:)` calls the whole
    /// target `.bridgeEffectV2` as soon as ONE light is v2-capable, so in a
    /// mixed room (1 v2 + 2 legacy) `base_color`/`warmth` resolved `.active`
    /// against full COLOUR coverage and claimed the whole room — while two of
    /// the three lights never moved. The transport-shaped caveat could not
    /// catch it either: the room is not `.legacy`.
    ///
    /// Coverage is the honest answer, and the resolver cannot reach it — it
    /// measured `.color`/`.colorTemperature`, which really are full here. So
    /// the funnel narrows the answer afterwards, at exactly the level that
    /// knows both facts.
    private static let perLightEffectsV2ParamIDs: Set<String> =
        ["base_color", "warmth", "speed"]

    /// Narrow a satisfied bridge-native answer to the `effects_v2` subset.
    ///
    /// Only ever narrows: an already-`.partial` answer keeps whichever
    /// coverage is smaller, and staged/unavailable/hidden are left alone —
    /// they are being honest about a bigger problem already. `speed` already
    /// requires `.effectsV2`, so it passes through unchanged; it is listed
    /// because the rule is about the SEND PATH, not about which requirement
    /// happens to imply it today.
    private static func narrowedToEffectsV2Coverage(
        _ resolution: CustomizationResolution,
        card: StudioCard,
        param: StudioParam,
        snapshot: CustomizationTargetSnapshot
    ) -> CustomizationResolution {
        guard case .bridgeNative = card.strategy,
              perLightEffectsV2ParamIDs.contains(param.id),
              snapshot.effectsV2.isPartial else { return resolution }

        let v2 = snapshot.effectsV2
        let narrowed: CustomizationAvailability
        switch resolution.availability {
        case .active:
            narrowed = .partial(supported: v2.supported, total: v2.total,
                                reason: .partialHardwareCoverage)
        case .partial(let supported, _, let reason):
            guard v2.supported < supported else { return resolution }
            narrowed = .partial(supported: v2.supported, total: v2.total, reason: reason)
        case .staged, .unavailable, .hidden:
            return resolution
        }
        return CustomizationResolution(control: resolution.control,
                                       availability: narrowed,
                                       behavior: resolution.behavior)
    }

    /// Does this control's send path still owe a hardware check?
    ///
    /// Asked only where the resolver already said yes. A staged or unavailable
    /// control is being honest already, and stacking "…and we are not sure it
    /// works" on top of it would read as two separate problems.
    ///
    /// The MEMBERSHIP question — which params owe a check — is answered by
    /// `EffectParameterProfiles.pendingHardwareChecks`, the same list the
    /// on-device checklist and the capability matrix are generated from. This
    /// used to be a local rule (`.hardwarePending` evidence, plus a hardcoded
    /// grouped-fallback pair) that silently disagreed with it: `speed` owes a
    /// per-effect, per-model firmware-response check and was labelled as
    /// proven on every board.
    private static func isHardwareUnverified(
        card: StudioCard,
        param: StudioParam,
        snapshot: CustomizationTargetSnapshot,
        availability: CustomizationAvailability
    ) -> Bool {
        switch availability {
        case .active, .partial:                 break
        case .staged, .unavailable, .hidden:    return false
        }
        guard case .bridgeNative(let effectName) = card.strategy,
              EffectParameterProfiles.profile(effect: effectName,
                                              paramID: param.id) != nil,
              EffectParameterProfiles.pendingHardwareCheckParamIDs.contains(param.id) else {
            return false
        }
        // `base_color`/`warmth` owe their check only where the v1-only grouped
        // approximation stands in for the proven per-light v2 write.
        if EffectParameterProfiles.groupedFallbackOnlyChecks.contains(param.id) {
            return snapshot.transport == .legacy
        }
        // `brightness` and `speed`: owed everywhere.
        return true
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

    /// The funnel's interactivity answer, INCLUDING the nil case.
    ///
    /// Nil used to mean "interactive" everywhere, which is fail-open in the one
    /// place it must not be: a bridge-native param absent from the audit-§7
    /// table has NO proven send path, so a live-looking control there is the
    /// original defect wearing a different hat. Composition boards keep the
    /// old answer — they declare no params here at all, so nil there means
    /// "not this funnel's business", not "unproven".
    static func isInteractive(resolution: StudioBoardResolution?,
                              strategy: StudioStrategy) -> Bool {
        guard let resolution else { return unresolvedIsInteractive(strategy) }
        return isInteractive(resolution.availability)
    }

    /// What an unresolved (nil) control may do, by card strategy.
    private static func unresolvedIsInteractive(_ strategy: StudioStrategy) -> Bool {
        switch strategy {
        case .bridgeNative:             return false   // no proven send path
        case .appDriven, .composition:  return true
        }
    }

    /// Whether the control renders at all. Spec §17's Hidden state is "do not
    /// render", not "render greyed out" — a dimmed dead control is exactly the
    /// thing Hidden exists to avoid.
    static func rendersControl(_ resolution: StudioBoardResolution?) -> Bool {
        resolution.map { $0.availability.rendersControl } ?? true
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

    /// Presentation opacity through the funnel, including the nil case and the
    /// hardware-unverified quieting: an active-but-unproven control is still
    /// fully editable, but it must not LOOK like a control we can vouch for.
    static func opacity(resolution: StudioBoardResolution?,
                        strategy: StudioStrategy) -> Double {
        guard let resolution else {
            return unresolvedIsInteractive(strategy) ? 1 : disabledOpacity
        }
        if resolution.isHardwareUnverified { return stagedOpacity }
        return opacity(resolution.availability)
    }

    // ── Copy ────────────────────────────────────────────────────

    /// Human copy for a not-fully-live control — no API jargon, one note per
    /// control.
    ///
    /// `isColor` suppresses the partial-coverage line: the inline colour
    /// editor already badges "n OF m LIGHTS" beside its own chip, and saying
    /// it twice reads as two different problems.
    /// "We are still asking the bridge."
    ///
    /// The board refreshes itself when the inventory lands (Guard 15(j) pins
    /// the observable fact that wakes it), so the copy no longer promises a
    /// refresh — it just names the state. The long form wrapped to four-plus
    /// lines under a knob in a three-column grid, which made the amber caption
    /// the largest thing on the board.
    static let checkingCopy = "CHECKING WHAT THESE LIGHTS SUPPORT"
    /// Coverage and the evidence caveat, when a control owes both.
    static let noteSeparator = " · "

    static func note(for resolution: StudioBoardResolution,
                     isColor: Bool) -> String? {
        // Nothing to render, nothing to say.
        guard resolution.availability.rendersControl else { return nil }

        // A target with no lights at all is not "still checking", and it is
        // not partially covered either — nothing is ever going to answer.
        // This outranks EVERY availability: the old placement inside the
        // `.unavailable` branch let a `.staged` or `.partial` answer on an
        // empty room say "STREAMING ONLY" or "0 OF 0 LIGHTS RESPOND".
        if resolution.totalLights == 0 { return "NO LIGHTS HERE" }

        // The evidence caveat COEXISTS with coverage — it does not replace it.
        // Swallowing the count made a mixed room's `base_color` say only
        // "UNVERIFIED ON THESE LIGHTS" and drop the far more actionable "1 OF
        // 3 LIGHTS RESPOND". Coverage is about WHICH lights, evidence is about
        // WHETHER; both are true, so both are said.
        let unverified = resolution.isHardwareUnverified ? "UNVERIFIED ON THESE LIGHTS" : nil

        switch resolution.availability {
        case .active, .hidden:
            return unverified

        case .partial(let supported, let total, _):
            // The colour editor already badges "n OF m LIGHTS" beside its own
            // chip; saying it twice reads as two problems. The caveat is not
            // badged anywhere, so it survives.
            let coverage = isColor ? nil : "\(supported) OF \(total) LIGHTS RESPOND"
            let parts = [coverage, unverified].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: noteSeparator)

        case .staged(let reason, _):
            // The transport-shaped stage is the one the user can act on, so
            // it gets its own words; every other staged reason keeps the
            // existing generic copy.
            return reason == .requiresEntertainment
                ? "STREAMING ONLY — INACTIVE IN ROOM MODE"
                : "SAVED — APPLIES WHEN SUPPORT ARRIVES"

        case .unavailable(let reason, let remediation):
            switch reason {
            case .effectsV2Unavailable:
                // Reachable only from the UNSUPPORTED branch of the resolver
                // now — the bridge answered and said no. An UNKNOWN
                // `effects_v2` used to land here too, which is how a cold
                // snapshot's Speed knob asserted a hardware refusal beside
                // three siblings that correctly said we were still checking.
                return "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING"
            case .noCTCapableLights:
                return "NO WHITE-TONE LIGHTS HERE"
            case .noColorCapableLights:
                return "NO COLOR LIGHTS HERE"
            case .capabilityUnknown, .capabilityUnreadable:
                return checkingCopy
            case .effectParameterUnverified:
                // One reason, two outcomes. The resolver offers a retry only
                // for the UNKNOWN pair ("never verified"); the unsupported
                // flavour — the effect really has no such parameter — carries
                // no remediation. Unknown must read as checking, never as a
                // refusal.
                return remediation == .retryCapabilityFetch
                    ? checkingCopy
                    : "NOT AVAILABLE FOR THESE LIGHTS"
            default:
                return "NOT AVAILABLE FOR THESE LIGHTS"
            }
        }
    }

    /// The funnel's note, INCLUDING the nil case. A bridge-native control the
    /// audit-§7 table cannot vouch for is not silently live — it says so.
    static func note(for resolution: StudioBoardResolution?,
                     strategy: StudioStrategy,
                     isColor: Bool) -> String? {
        guard let resolution else {
            return unresolvedIsInteractive(strategy) ? nil : "NOT AVAILABLE FOR THESE LIGHTS"
        }
        return note(for: resolution, isColor: isColor)
    }
}
