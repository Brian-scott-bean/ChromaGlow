//
//  CustomizationSnapshotBuilder.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (Production Truth Wiring).
//
//  Assembles the pure `CustomizationTargetSnapshot` the resolver consumes,
//  from cached light data — never from a fetch. This file is the honesty
//  boundary the audit demanded:
//
//  * A FAILED capability read produces a snapshot whose coverages carry
//    `.unreadable` evidence — controls resolve unavailable-with-retry
//    instead of standing on stale numbers. The old `refreshCoverage`
//    silently returned on failure and left the previous room's coverage
//    on screen; this type cannot express that.
//  * CT honesty: the mirek range is the INTERSECTION of every CT-capable
//    light's decoded `mirek_schema`. A light that claims CT without a
//    readable schema downgrades the evidence to `.unreadable`, and the
//    resolver then answers `.unknown` — never a fake 153…500.
//  * `verifiedEffectParameters` comes from `EffectParameterProfiles`
//    (audit §7): only code-proven live parameters appear; everything else
//    resolves `.unknown` and renders staged/unavailable, never active.
//

import Foundation

enum CustomizationSnapshotBuilder {

    /// Build a snapshot from a successfully read light inventory.
    ///
    /// `lights` must already be scoped to the target (the caller resolves
    /// room/zone membership); `declaredEffectParams` maps a bridge-native
    /// effect name to the paramIDs its card declares, so the verified table
    /// can be filtered to what the UI could actually show.
    /// `runningEffectV2Name` is the bridge-native effect currently RUNNING on
    /// the target, when one is. It makes `effectsV2` effect-specific: the live
    /// per-light write reaches exactly the lights whose
    /// `effects_v2.action.effect_values` contain that name — the same rule
    /// `applyStudioEffectV2Parameters` uses to build `v2CapableLightIDs` — and
    /// generic support is a strictly larger set. A room of one cosmos-capable
    /// light and two candle/fire-only lights reported 3 of 3 while Cosmos ran,
    /// so colour, warmth and speed claimed the whole room and two thirds of it
    /// never moved.
    static func snapshot(identity: RunningLookIdentity,
                         lights: [HueLight],
                         declaredEffectParams: [String: [String]] = [:],
                         runningEffectV2Name: String? = nil,
                         entertainmentAvailable: CapabilityEvidence,
                         transport: CustomizationTransport,
                         running: Bool) -> CustomizationTargetSnapshot {
        let total = lights.count

        func coverage(_ supported: Int) -> CapabilityCoverage {
            CapabilityCoverage(supported: supported, total: total,
                               evidence: supported > 0 ? .known : .unsupported)
        }

        let dimmingCount = lights.filter { $0.dimming != nil }.count
        let colorCount = lights.filter { $0.color != nil }.count
        let gradientCount = EffectCapabilityResolver.gradientLights(lights).count
        // GENERIC v2 support — the fallback answer when nothing bridge-native
        // is running and there is no effect to be specific about.
        let genericV2 = lights.filter { EffectCapabilityResolver.supportsEffectsV2($0) }

        // EFFECT-SPECIFIC reach. Deliberately NOT
        // `EffectCapabilityResolver.effectValues(for:)`, which falls back to
        // the legacy v1 list: a light that can run this effect only through
        // the v1 enum takes no `effects_v2` body, so counting it would put the
        // overstatement straight back.
        let effectSpecificV2: [HueLight]? = runningEffectV2Name.map { name in
            lights.filter { ($0.effects_v2?.action?.effect_values ?? []).contains(name) }
        }
        let v2Lights = effectSpecificV2 ?? genericV2
        let v2Count = v2Lights.count

        // The TRUE intersections, so a caller narrowing a colour or warmth
        // control does not have to take `min(v2, colour)` — the two sets only
        // partly overlap, and the min overstates every partial overlap.
        var effectV2ColorLights: Int? = nil
        var effectV2CTLights: Int? = nil
        if let effectSpecificV2 {
            effectV2ColorLights = effectSpecificV2.filter { $0.color != nil }.count
            effectV2CTLights = effectSpecificV2.filter { $0.color_temperature != nil }.count
        }

        // CT: capable lights, and the intersected range across the ones whose
        // schema is readable. Capable-but-schemaless downgrades the evidence.
        let ctLights = lights.filter { $0.color_temperature != nil }
        var ctRange: MirekRange? = nil
        var ctSchemaless = false
        for light in ctLights {
            guard let schema = light.color_temperature?.mirek_schema,
                  let range = MirekRange(minMirek: schema.mirek_minimum,
                                         maxMirek: schema.mirek_maximum) else {
                ctSchemaless = true
                continue
            }
            ctRange = ctRange.map { $0.intersected(with: range) } ?? range
        }
        let ctEvidence: CapabilityEvidence =
            ctLights.isEmpty ? .unsupported : (ctSchemaless ? .unreadable : .known)
        let ctCoverage = CapabilityCoverage(supported: ctLights.count, total: total,
                                            evidence: ctEvidence)

        var verified: [String: Set<String>] = [:]
        for (effect, paramIDs) in declaredEffectParams {
            verified[effect] = EffectParameterProfiles.verifiedLiveParameters(
                for: effect, declaredParamIDs: paramIDs)
        }

        return CustomizationTargetSnapshot(
            identity: identity,
            totalLights: total,
            dimming: coverage(dimmingCount),
            color: coverage(colorCount),
            colorTemperature: ctCoverage,
            mirekRange: ctSchemaless ? nil : ctRange,
            gradient: coverage(gradientCount),
            effectsV2: coverage(v2Count),
            effectV2ColorLights: effectV2ColorLights,
            effectV2CTLights: effectV2CTLights,
            verifiedEffectParameters: verified,
            entertainmentAvailable: entertainmentAvailable,
            transport: transport,
            running: running)
    }

    /// The snapshot for a target whose capability read FAILED. Every axis
    /// carries `.unreadable` — unknown, not unsupported — so controls resolve
    /// unavailable-with-retry instead of inheriting stale numbers.
    static func unreadable(identity: RunningLookIdentity,
                           totalLights: Int,
                           transport: CustomizationTransport,
                           running: Bool) -> CustomizationTargetSnapshot {
        let unread = CapabilityCoverage(supported: 0, total: totalLights,
                                        evidence: .unreadable)
        return CustomizationTargetSnapshot(
            identity: identity,
            totalLights: totalLights,
            dimming: unread, color: unread, colorTemperature: unread,
            mirekRange: nil, gradient: unread, effectsV2: unread,
            // Unreadable stays unreadable: an intersection of two sets we
            // could not read is not zero, it is unknown.
            effectV2ColorLights: nil, effectV2CTLights: nil,
            verifiedEffectParameters: [:],
            entertainmentAvailable: .unreadable,
            transport: transport,
            running: running)
    }
}
