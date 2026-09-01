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
    static func snapshot(identity: RunningLookIdentity,
                         lights: [HueLight],
                         declaredEffectParams: [String: [String]] = [:],
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
        let v2Count = lights.filter { EffectCapabilityResolver.supportsEffectsV2($0) }.count

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
            verifiedEffectParameters: [:],
            entertainmentAvailable: .unreadable,
            transport: transport,
            running: running)
    }
}
