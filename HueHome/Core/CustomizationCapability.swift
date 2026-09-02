//
//  CustomizationCapability.swift
//  HueHome
//
//  Unified Customization Engine — Slice 1 (Truth Foundation).
//
//  WHAT THIS REPLACES
//  ──────────────────
//  A control's hardware requirement started as one boolean: `StudioParam.entOnly`
//  (declared `StudioViewModel.swift:86`, set on seven params after the Slice 2
//  engine reverse-audit — party.speed, party.min_brightness, strobe.speed,
//  strobe.flash_color, strobe.duty_cycle, thunderstorm.flash_length,
//  thunderstorm.afterglow). The flag is now catalog metadata only: its single
//  live consumer is `StudioBoardAvailability.descriptor(card:param:)`, which
//  translates it into `.transport(.entertainment)` so the resolver — not a view
//  body — decides. (The old citation here, `StudioParamControls.swift:119`, is
//  dead: `StudioParamRow`/`StudioParamSheet` have no production caller.)
//  One bit cannot express "needs colour", "needs a real CT range", "needs
//  effects_v2 on at least one light", "works on some of these lights", or —
//  critically — "we do not KNOW yet".
//
//  Execution plan §8 asks for composable requirement metadata instead. This is
//  it. A requirement is a small predicate tree; a target is a snapshot of what
//  the hardware can actually do; evaluating one against the other yields
//  evidence, never a guess.
//
//  THE HONESTY RULE (spec §17, audit §5)
//  ─────────────────────────────────────
//  Unknown must never silently become unsupported. `.unknown` is a distinct
//  result and it propagates: if any part of a requirement is unknown and no
//  part is outright unsupported, the whole requirement is unknown.
//
//  Pure: no SwiftUI, no networking, no I/O.
//

import Foundation

// ──────────────────────────────────────────────────────────────
// MARK: - Evidence quality
// ──────────────────────────────────────────────────────────────

/// How much we actually know about one capability of one target.
///
/// This is the axis the old boolean had no room for. `.unreadable` and
/// `.absent` are both "we cannot prove support", but they mean different
/// things to the user and produce different remediation copy.
enum CapabilityEvidence: String, Hashable, Sendable {
    /// Decoded from the bridge and trusted.
    case known
    /// The bridge answered, and the capability block was not present.
    case absent
    /// The bridge answered and said no.
    case unsupported
    /// We asked and could not read the answer (fetch failed, malformed).
    case unreadable
    /// We have not asked yet.
    case unknown

    /// Only `.known` lets a control render as active on hardware grounds.
    var isProven: Bool { self == .known }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Target capability snapshot
// ──────────────────────────────────────────────────────────────

/// Coverage of one capability across the lights in a target.
///
/// `supported` / `total` is what turns a binary control into an honest
/// "partial" one — spec §17's Partial state is not expressible without it.
struct CapabilityCoverage: Hashable, Sendable {
    let supported: Int
    let total: Int
    let evidence: CapabilityEvidence

    init(supported: Int, total: Int, evidence: CapabilityEvidence) {
        self.supported = max(0, supported)
        self.total = max(0, total)
        self.evidence = evidence
    }

    static func none(total: Int, evidence: CapabilityEvidence = .unsupported) -> CapabilityCoverage {
        CapabilityCoverage(supported: 0, total: total, evidence: evidence)
    }

    static func all(total: Int) -> CapabilityCoverage {
        CapabilityCoverage(supported: total, total: total, evidence: .known)
    }

    static func unknown(total: Int) -> CapabilityCoverage {
        CapabilityCoverage(supported: 0, total: total, evidence: .unknown)
    }

    var isFull: Bool { evidence.isProven && total > 0 && supported == total }
    var isPartial: Bool { evidence.isProven && supported > 0 && supported < total }
    var isNone: Bool { supported == 0 }
}

/// Mirek (reciprocal megakelvin) range a target can actually honour.
///
/// Stored in mirek because that is what the bridge speaks and what the app
/// persists; the Kelvin formatter is a presentation concern (audit §19).
struct MirekRange: Hashable, Sendable {
    let minMirek: Int
    let maxMirek: Int

    init?(minMirek: Int, maxMirek: Int) {
        guard minMirek <= maxMirek else { return nil }
        self.minMirek = minMirek
        self.maxMirek = maxMirek
    }

    /// The safe intersection across mixed fixtures. Nil when they do not
    /// overlap at all — which the UI must show as unavailable, not clamp away.
    func intersected(with other: MirekRange) -> MirekRange? {
        MirekRange(minMirek: max(minMirek, other.minMirek),
                   maxMirek: min(maxMirek, other.maxMirek))
    }
}

/// Which transport is actually carrying this look right now.
enum CustomizationTransport: String, Hashable, Sendable {
    /// DTLS Entertainment session — live per-frame mutation.
    case entertainment
    /// Room-scoped REST writes.
    case roomREST
    /// Firmware effect running on the bridge (`effects_v2`).
    case bridgeEffectV2
    /// Legacy v1 grouped/per-light state.
    case legacy
    /// Nothing running.
    case none
}

/// Everything the resolver is allowed to know about the selected target.
///
/// Built once from cached orchestrator/light data and handed in. The resolver
/// never fetches (spec §27: no capability fetch from a view body, and no I/O
/// in the pure layer at all).
struct CustomizationTargetSnapshot: Hashable, Sendable {
    let identity: RunningLookIdentity

    /// Lights in the target.
    let totalLights: Int
    /// Lights the bridge currently reports reachable, if known.
    let reachableLights: Int?

    let dimming: CapabilityCoverage
    let color: CapabilityCoverage
    let colorTemperature: CapabilityCoverage
    /// Intersected CT range across the CT-capable lights, if any.
    let mirekRange: MirekRange?
    let gradient: CapabilityCoverage
    /// Lights this target's live `effects_v2` write can actually reach.
    ///
    /// EFFECT-SPECIFIC while a bridge-native look is running, not generic
    /// `effects_v2` support. The send fans out to exactly the lights whose
    /// `effects_v2.action.effect_values` contain THIS effect's name, so a room
    /// where one light lists `cosmos` and two list only `candle`/`fire` has
    /// generic support 3/3 and a real reach of 1/3 while Cosmos runs. Reporting
    /// the generic number let `base_color`/`warmth`/`speed` claim the whole
    /// room while two of its three lights never moved.
    ///
    /// With nothing bridge-native running there is no effect to be specific
    /// about, and this is the generic support count.
    let effectsV2: CapabilityCoverage
    /// Effect-specific `effects_v2` lights that are ALSO colour-capable, when
    /// the intersection is known. Nil where it was never computed (an
    /// unreadable target, or no bridge-native effect running).
    ///
    /// The two sets are not nested: a light can take the effect without doing
    /// colour, and vice versa. `min(effectsV2, color)` therefore OVERSTATES
    /// the reach of a colour control whenever they only partly overlap — this
    /// is the true count.
    let effectV2ColorLights: Int?
    /// The same intersection for colour temperature.
    let effectV2CTLights: Int?
    /// Per-effect verified parameter support, keyed by effect id. Absent key
    /// means "not verified" — which resolves to `.unknown`, never to yes.
    let verifiedEffectParameters: [String: Set<String>]

    let entertainmentAvailable: CapabilityEvidence
    let transport: CustomizationTransport
    /// Is anything running on this target right now?
    let isRunning: Bool

    init(identity: RunningLookIdentity,
         totalLights: Int,
         reachableLights: Int? = nil,
         dimming: CapabilityCoverage,
         color: CapabilityCoverage,
         colorTemperature: CapabilityCoverage,
         mirekRange: MirekRange? = nil,
         gradient: CapabilityCoverage,
         effectsV2: CapabilityCoverage,
         effectV2ColorLights: Int? = nil,
         effectV2CTLights: Int? = nil,
         verifiedEffectParameters: [String: Set<String>] = [:],
         entertainmentAvailable: CapabilityEvidence,
         transport: CustomizationTransport,
         running: Bool) {
        self.identity = identity
        self.totalLights = totalLights
        self.reachableLights = reachableLights
        self.dimming = dimming
        self.color = color
        self.colorTemperature = colorTemperature
        self.mirekRange = mirekRange
        self.gradient = gradient
        self.effectsV2 = effectsV2
        self.effectV2ColorLights = effectV2ColorLights
        self.effectV2CTLights = effectV2CTLights
        self.verifiedEffectParameters = verifiedEffectParameters
        self.entertainmentAvailable = entertainmentAvailable
        self.transport = transport
        self.isRunning = running
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Requirements
// ──────────────────────────────────────────────────────────────

/// What a control needs in order to be honestly interactive.
///
/// Composable by design — execution plan §8 explicitly asks for predicates
/// over "a growing list of increasingly specific special cases". `entOnly`
/// becomes `.transport(.entertainment)`; everything the old flag could not say
/// becomes sayable.
indirect enum CapabilityRequirement: Hashable, Sendable {
    /// Always satisfiable — the control has no hardware precondition.
    case none
    /// At least one light must dim.
    case dimming
    /// At least one light must render colour.
    case color
    /// At least one light must honour CT, with a real mirek range.
    case colorTemperature
    /// At least one light must be gradient-capable.
    case gradient
    /// At least one light must have accepted `effects_v2`.
    case effectsV2
    /// The named firmware effect must have this parameter VERIFIED. An
    /// unverified pair is `.unknown`, never supported (audit §7).
    case effectParameter(effect: String, parameter: String)
    /// This exact transport must be carrying the look.
    case transport(CustomizationTransport)
    /// Entertainment must at least be available on this bridge.
    case entertainmentAvailable
    /// Something must be running for this control to mean anything.
    case running

    case all([CapabilityRequirement])
    case any([CapabilityRequirement])
}

/// The outcome of measuring one requirement against one target.
enum RequirementOutcome: Hashable, Sendable {
    case satisfied
    case partial(supported: Int, total: Int)
    case unsupported(CapabilityRequirement)
    case unknown(CapabilityRequirement)

    var isSatisfiedOrPartial: Bool {
        switch self {
        case .satisfied, .partial: return true
        case .unsupported, .unknown: return false
        }
    }
}

extension CapabilityRequirement {

    /// Measure this requirement against a target snapshot.
    ///
    /// Pure. Deterministic. The whole point of Slice 1 is that this function —
    /// not a SwiftUI `if card.id == …` chain — decides what the user may touch.
    func evaluate(against target: CustomizationTargetSnapshot) -> RequirementOutcome {
        switch self {
        case .none:
            return .satisfied

        case .dimming:            return Self.outcome(for: target.dimming, self)
        case .color:              return Self.outcome(for: target.color, self)
        case .gradient:           return Self.outcome(for: target.gradient, self)
        case .effectsV2:          return Self.outcome(for: target.effectsV2, self)

        case .colorTemperature:
            // CT needs BOTH a capable light and a usable range. A fixture that
            // claims CT with no readable range is unknown, not supported.
            let base = Self.outcome(for: target.colorTemperature, self)
            guard base.isSatisfiedOrPartial else { return base }
            guard target.mirekRange != nil else { return .unknown(self) }
            return base

        case .effectParameter(let effect, let parameter):
            guard let verified = target.verifiedEffectParameters[effect] else {
                return .unknown(self)          // never verified → never guessed
            }
            return verified.contains(parameter) ? .satisfied : .unsupported(self)

        case .transport(let required):
            if target.transport == required { return .satisfied }
            // Not running yet is "we cannot tell", not "no".
            if target.transport == .none && !target.isRunning { return .unknown(self) }
            return .unsupported(self)

        case .entertainmentAvailable:
            switch target.entertainmentAvailable {
            case .known:                    return .satisfied
            case .unknown, .unreadable:     return .unknown(self)
            case .absent, .unsupported:     return .unsupported(self)
            }

        case .running:
            return target.isRunning ? .satisfied : .unsupported(self)

        case .all(let parts):
            return Self.combineAll(parts, against: target, origin: self)

        case .any(let parts):
            return Self.combineAny(parts, against: target, origin: self)
        }
    }

    // ── Combinators ─────────────────────────────────────────────

    private static func combineAll(_ parts: [CapabilityRequirement],
                                   against target: CustomizationTargetSnapshot,
                                   origin: CapabilityRequirement) -> RequirementOutcome {
        guard !parts.isEmpty else { return .satisfied }
        var sawUnknown = false
        var worstPartial: (supported: Int, total: Int)?

        for part in parts {
            switch part.evaluate(against: target) {
            case .satisfied:
                continue
            case .partial(let s, let t):
                // The narrowest coverage wins: a control is only as available
                // as its least-supported precondition.
                if let current = worstPartial {
                    if s < current.supported { worstPartial = (s, t) }
                } else {
                    worstPartial = (s, t)
                }
            case .unsupported(let r):
                return .unsupported(r)        // one hard no ends it
            case .unknown:
                sawUnknown = true
            }
        }

        // Unknown outranks partial: we must not claim partial coverage on a
        // capability we could not read.
        if sawUnknown { return .unknown(origin) }
        if let p = worstPartial { return .partial(supported: p.supported, total: p.total) }
        return .satisfied
    }

    private static func combineAny(_ parts: [CapabilityRequirement],
                                   against target: CustomizationTargetSnapshot,
                                   origin: CapabilityRequirement) -> RequirementOutcome {
        guard !parts.isEmpty else { return .satisfied }
        var sawUnknown = false
        var bestPartial: (supported: Int, total: Int)?

        for part in parts {
            switch part.evaluate(against: target) {
            case .satisfied:
                return .satisfied              // one yes is enough
            case .partial(let s, let t):
                if let current = bestPartial {
                    if s > current.supported { bestPartial = (s, t) }
                } else {
                    bestPartial = (s, t)
                }
            case .unknown:
                sawUnknown = true
            case .unsupported:
                continue
            }
        }

        if let p = bestPartial { return .partial(supported: p.supported, total: p.total) }
        if sawUnknown { return .unknown(origin) }
        return .unsupported(origin)
    }

    private static func outcome(for coverage: CapabilityCoverage,
                                _ requirement: CapabilityRequirement) -> RequirementOutcome {
        switch coverage.evidence {
        case .unknown, .unreadable:
            return .unknown(requirement)
        case .absent, .unsupported:
            return .unsupported(requirement)
        case .known:
            if coverage.isFull { return .satisfied }
            if coverage.isPartial {
                return .partial(supported: coverage.supported, total: coverage.total)
            }
            return .unsupported(requirement)
        }
    }
}
