//
//  CustomizationResolver.swift
//  HueHome
//
//  Unified Customization Engine — Slice 1 (Truth Foundation).
//
//  The one place that answers spec §17: given a control's requirement, the
//  target's real capability, the live transport and the running state, what
//  availability state does this control resolve to — and, separately, how does
//  a change to it actually reach the lights?
//
//  Availability and mutation behaviour are deliberately two answers, not one
//  (execution plan §7). "You may touch this" and "this takes effect on the next
//  restart" are orthogonal, and collapsing them is how a slider ends up moving
//  while silently doing nothing — the defect spec §17 names outright.
//
//  Pure: no SwiftUI, no networking, no I/O, no clock.
//

import Foundation

// ──────────────────────────────────────────────────────────────
// MARK: - Availability (spec §17)
// ──────────────────────────────────────────────────────────────

/// What the user may do with a control, right now, on this exact target.
enum CustomizationAvailability: Hashable, Sendable {
    /// Changing it affects the selected running look now.
    case active
    /// A known subset of the target responds; coverage is stated.
    case partial(supported: Int, total: Int, reason: CustomizationReason)
    /// Editable and saved, but intentionally not affecting current output.
    case staged(reason: CustomizationReason, remediation: CustomizationRemediation?)
    /// The concept applies, but hardware or transport cannot honour it now.
    case unavailable(reason: CustomizationReason, remediation: CustomizationRemediation?)
    /// Irrelevant in this context — do not render at all.
    case hidden

    var rendersControl: Bool { self != .hidden }

    /// True only for `.active`. Anything else must not present as a plain,
    /// fully-live control.
    var isFullyLive: Bool { self == .active }
}

/// Why a control is in its state. A closed vocabulary rather than free text so
/// tests can assert on it and the UI can localise it.
enum CustomizationReason: String, Hashable, Sendable {
    case noColorCapableLights
    case noCTCapableLights
    case noDimmableLights
    case noGradientLights
    case effectsV2Unavailable
    case effectParameterUnverified
    case requiresEntertainment
    case entertainmentUnavailable
    case notRunning
    case partialHardwareCoverage
    case capabilityUnknown
    case capabilityUnreadable
    case notApplicableToThisLook
    case readOnlyComposition
}

/// What the user could do about it. Nil when there is nothing useful to say.
enum CustomizationRemediation: String, Hashable, Sendable {
    case startTheLook
    case enableStreaming
    case selectDifferentRoom
    case addCapableLights
    case retryCapabilityFetch
    case openInComposer
}

// ──────────────────────────────────────────────────────────────
// MARK: - Mutation behaviour (execution plan §7)
// ──────────────────────────────────────────────────────────────

/// How a change to this control actually reaches the lights.
enum CustomizationMutationBehavior: String, Hashable, Sendable {
    /// Lands on the next engine frame.
    case immediate
    /// Coalesced, then sent — the window where a stale write can outlive its
    /// target, which is why every debounced path must be fenced.
    case debounced
    /// Picked up at the start of the next animation cycle.
    case nextCycle
    /// Requires re-sending the effect to the bridge.
    case requiresReapply
    /// Requires stopping and restarting the look.
    case requiresRestart
    /// Stored now, applied when the enabling condition arrives.
    case staged
    /// Sends nothing itself — it shapes the NEXT write (Slice 2, for the
    /// bridge-native `transition`/Smoothness parameter, which only feeds the
    /// `dynamics.duration` of subsequent brightness/warmth/color sends).
    /// The audit demanded an honest class for this instead of pretending it
    /// is a live effect parameter.
    case nextWrite

    /// Behaviours that can have a write in flight when the world changes.
    /// These are precisely the ones `CustomizationFence` must guard.
    var canLandLate: Bool {
        switch self {
        case .debounced, .nextCycle, .requiresReapply:            return true
        case .immediate, .requiresRestart, .staged, .nextWrite:   return false
        }
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Control descriptor
// ──────────────────────────────────────────────────────────────

/// The semantic identity of one customizable control.
///
/// `controlID` is scoped by card on purpose: `party.color` and
/// `thunderstorm.flash_color` are different controls that happen to both be
/// colours, and the dead-sentinel list is written in exactly this `card.param`
/// notation (audit §9). Comparing whole `ControlID`s — never substrings — is
/// what stops a check for the dead `ambient.color` from matching the LIVE
/// `thunderstorm.ambient_color`.
struct CustomizationControlID: Hashable, Sendable, CustomStringConvertible {
    let cardID: String
    let paramID: String

    init(cardID: String, paramID: String) {
        self.cardID = cardID
        self.paramID = paramID
    }

    var description: String { "\(cardID).\(paramID)" }
}

/// Everything the resolver needs to know about a control, independent of any
/// particular target. Built from the catalog once.
struct CustomizationControlDescriptor: Hashable, Sendable {
    let id: CustomizationControlID
    let requirement: CapabilityRequirement
    /// Behaviour when the requirement is fully met.
    let liveBehavior: CustomizationMutationBehavior
    /// Behaviour when the look is not running. Usually `.staged`.
    let idleBehavior: CustomizationMutationBehavior
    /// Cards this control may appear on. A control resolves to `.hidden` on
    /// any other card — this is what makes "no orphan controls" checkable.
    let appliesToExecution: Set<String>

    init(id: CustomizationControlID,
         requirement: CapabilityRequirement,
         liveBehavior: CustomizationMutationBehavior = .immediate,
         idleBehavior: CustomizationMutationBehavior = .staged,
         appliesToExecution: Set<String> = []) {
        self.id = id
        self.requirement = requirement
        self.liveBehavior = liveBehavior
        self.idleBehavior = idleBehavior
        self.appliesToExecution = appliesToExecution
    }
}

/// The resolver's complete answer for one control on one target.
struct CustomizationResolution: Hashable, Sendable {
    let control: CustomizationControlID
    let availability: CustomizationAvailability
    let behavior: CustomizationMutationBehavior
}

// ──────────────────────────────────────────────────────────────
// MARK: - The resolver
// ──────────────────────────────────────────────────────────────

/// Pure, deterministic, total. Same inputs always give the same answer, and it
/// cannot touch the network — which is what lets the whole availability matrix
/// be a unit test rather than a device checklist.
enum CustomizationResolver {

    static func resolve(control: CustomizationControlDescriptor,
                        on target: CustomizationTargetSnapshot) -> CustomizationResolution {

        // 1. Does this control belong on this look at all? Wrong-card controls
        //    are hidden, not disabled — spec §17's Hidden state.
        if !control.appliesToExecution.isEmpty,
           !control.appliesToExecution.contains(target.identity.cardID) {
            return CustomizationResolution(control: control.id,
                                           availability: .hidden,
                                           behavior: control.idleBehavior)
        }

        // 2. Measure the hardware/transport requirement.
        let outcome = control.requirement.evaluate(against: target)

        switch outcome {
        case .satisfied:
            // Capability is there. Running state decides live vs staged: a
            // control on a look that is not running is honest as `.staged`,
            // never as `.active`.
            if target.isRunning {
                return CustomizationResolution(control: control.id,
                                               availability: .active,
                                               behavior: control.liveBehavior)
            }
            return CustomizationResolution(
                control: control.id,
                availability: .staged(reason: .notRunning, remediation: .startTheLook),
                behavior: control.idleBehavior)

        case .partial(let supported, let total):
            // Some lights respond. The control stays usable and states its
            // coverage — silently pretending to full coverage is the defect.
            return CustomizationResolution(
                control: control.id,
                availability: .partial(supported: supported,
                                       total: total,
                                       reason: .partialHardwareCoverage),
                behavior: target.isRunning ? control.liveBehavior : control.idleBehavior)

        case .unknown(let requirement):
            // THE honesty rule (spec §17): unknown is not unsupported. The
            // control is unavailable *for now*, with a retry path — it does
            // not silently vanish, and it does not lie about being live.
            return CustomizationResolution(
                control: control.id,
                availability: .unavailable(reason: Self.unknownReason(for: requirement),
                                           remediation: .retryCapabilityFetch),
                behavior: control.idleBehavior)

        case .unsupported(let requirement):
            let (reason, remediation) = Self.unsupportedReason(for: requirement, on: target)
            // A transport-shaped "no" while the look IS running is staged, not
            // unavailable: the value is real and will apply the moment the
            // right transport arrives (audit §17).
            if case .transport = requirement, target.isRunning {
                return CustomizationResolution(
                    control: control.id,
                    availability: .staged(reason: reason, remediation: remediation),
                    behavior: .staged)
            }
            return CustomizationResolution(
                control: control.id,
                availability: .unavailable(reason: reason, remediation: remediation),
                behavior: control.idleBehavior)
        }
    }

    /// Resolve a whole catalog against one target, in a stable order.
    ///
    /// Sorted so the output is deterministic and diffable — the capability
    /// matrix is generated from exactly this.
    static func resolveAll(controls: [CustomizationControlDescriptor],
                           on target: CustomizationTargetSnapshot) -> [CustomizationResolution] {
        controls
            .sorted { $0.id.description < $1.id.description }
            .map { resolve(control: $0, on: target) }
    }

    // ── Reason mapping ──────────────────────────────────────────

    /// The reason for an UNKNOWN outcome.
    ///
    /// THE RULE THIS ENCODES: unknown must never read as a refusal. Nothing
    /// here may return a reason whose copy asserts a hardware fact, because
    /// the whole point of `.unknown` is that no hardware fact was read.
    ///
    /// `.effectsV2` used to map to `.effectsV2Unavailable` — the same reason
    /// the UNSUPPORTED branch returns — so a cold or unreadable snapshot made
    /// the Speed knob say "THESE LIGHTS CAN'T CHANGE THIS WHILE RUNNING"
    /// while `brightness`/`base_color`/`warmth` beside it, on the very same
    /// snapshot, correctly said we were still checking. One snapshot, two
    /// stories, and the louder one was a lie. `.effectsV2Unavailable` is now
    /// reachable ONLY from `unsupportedReason`.
    ///
    /// `.effectParameter` keeps `.effectParameterUnverified` — the audit's own
    /// word for "we have not verified this pair" — and the board renders that
    /// reason as the checking copy when a retry is offered (see
    /// `StudioBoardAvailability.note`), never as a hardware "no".
    ///
    /// `.capabilityUnreadable` stays reserved for a caller that wants to
    /// distinguish "the read failed" from "we have not asked"; both render
    /// identically today, so every coverage-shaped requirement answers with
    /// the one reason rather than splitting a distinction the user never sees.
    private static func unknownReason(for requirement: CapabilityRequirement) -> CustomizationReason {
        switch requirement {
        case .effectParameter: return .effectParameterUnverified
        default:               return .capabilityUnknown
        }
    }

    private static func unsupportedReason(
        for requirement: CapabilityRequirement,
        on target: CustomizationTargetSnapshot
    ) -> (CustomizationReason, CustomizationRemediation?) {
        switch requirement {
        case .color:
            return (.noColorCapableLights, .addCapableLights)
        case .colorTemperature:
            return (.noCTCapableLights, .addCapableLights)
        case .dimming:
            return (.noDimmableLights, .addCapableLights)
        case .gradient:
            return (.noGradientLights, .addCapableLights)
        case .effectsV2:
            return (.effectsV2Unavailable, .addCapableLights)
        case .effectParameter:
            return (.effectParameterUnverified, nil)
        case .transport(let wanted):
            return wanted == .entertainment
                ? (.requiresEntertainment, .enableStreaming)
                : (.notApplicableToThisLook, nil)
        case .entertainmentAvailable:
            return (.entertainmentUnavailable,
                    target.isRunning ? .selectDifferentRoom : .enableStreaming)
        case .running:
            return (.notRunning, .startTheLook)
        case .none, .all, .any:
            return (.notApplicableToThisLook, nil)
        }
    }
}
