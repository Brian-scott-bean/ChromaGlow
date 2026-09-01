//
//  EffectParameterProfilesTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2. Locks the audit-§7 verified
//  parameter profile table and the snapshot builder's honesty rules.
//
//  Lockstep convention (same as ENGINE_READS ↔ the engine-read allowlist):
//  the generator's EFFECT_PROFILES table mirrors EffectParameterProfiles —
//  these tests pin the Swift side; `generate_capability_matrix.py --check`
//  pins the rendered doc.
//

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class EffectParameterProfilesTests: XCTestCase {

    // ── The profile table ───────────────────────────────────────

    /// Every parameter every bridge-native card DECLARES has a profile row —
    /// no declared control is left unclassified.
    func testEveryDeclaredBridgeNativeParamHasAProfile() {
        let vm = StudioViewModel()
        for card in vm.effectCards {
            guard case .bridgeNative(let effect) = card.strategy else {
                XCTFail("effectCards must all be bridge-native"); continue
            }
            for param in card.params {
                XCTAssertNotNil(
                    EffectParameterProfiles.profile(effect: effect, paramID: param.id),
                    "\(card.id).\(param.id) is declared but has no verified profile")
            }
        }
    }

    /// The table exposes nothing the catalog does not declare — profiles for
    /// exactly the five parameter shapes, no invented Hue parameters.
    func testProfileTableCoversExactlyTheFiveDeclaredShapes() {
        let known = ["speed", "base_color", "warmth", "brightness", "transition"]
        for id in known {
            XCTAssertNotNil(EffectParameterProfiles.profile(effect: "candle", paramID: id))
        }
        for invented in ["saturation", "tint", "duration", "palette", "direction"] {
            XCTAssertNil(EffectParameterProfiles.profile(effect: "candle", paramID: invented),
                         "\(invented) has no verified evidence and must not be profiled")
        }
    }

    /// Speed's requirement is effects_v2 — there is no legacy branch in the
    /// send path, so a v1-only room must resolve it unavailable, never fake.
    func testSpeedRequiresEffectsV2() {
        let profile = EffectParameterProfiles.profile(effect: "candle", paramID: "speed")!
        XCTAssertEqual(profile.requirement, .effectsV2)
        XCTAssertEqual(profile.liveBehavior, .debounced)
    }

    /// Transition is the honest `.nextWrite` — it sends nothing, so it can
    /// never land late and the fence has nothing to guard.
    func testTransitionIsNextWriteAndCannotLandLate() {
        let profile = EffectParameterProfiles.profile(effect: "candle", paramID: "transition")!
        XCTAssertEqual(profile.liveBehavior, .nextWrite)
        XCTAssertFalse(CustomizationMutationBehavior.nextWrite.canLandLate)
    }

    /// Only code-proven LIVE paths count as verified; the hardware-pending
    /// brightness row is deliberately excluded so the resolver answers
    /// `.unknown` for it rather than faking active.
    func testVerifiedLiveParametersExcludeHardwarePendingRows() {
        let verified = EffectParameterProfiles.verifiedLiveParameters(
            for: "candle",
            declaredParamIDs: ["brightness", "speed", "warmth", "base_color", "transition"])
        XCTAssertEqual(verified, ["speed", "warmth", "base_color", "transition"])
        XCTAssertFalse(verified.contains("brightness"),
                       "brightness's visible behavior during a firmware effect is hardware-pending")
    }

    /// Prism and Color Loop still declare no tint/warmth — the audit's open
    /// question stays investigated-and-not-exposed, not silently invented.
    func testPrismAndColorLoopDeclareNoTintOrWarmth() {
        let vm = StudioViewModel()
        for id in ["prism", "colorloop"] {
            let card = vm.effectCards.first { $0.id == id }!
            XCTAssertFalse(card.params.contains { $0.id == "warmth" || $0.id == "base_color" },
                           "\(id) gained a color/warmth control without hardware evidence")
        }
    }

    // ── Snapshot builder honesty ────────────────────────────────

    private func identity() -> RunningLookIdentity {
        RunningLookIdentity(bridgeID: "bridge-a", groupID: "room-a", kind: .room,
                            cardID: "candle", execution: .bridgeNative(effect: "candle"),
                            generation: .initial)
    }

    private func light(_ id: String, ctMin: Int? = nil, ctMax: Int? = nil,
                       ctCapableNoSchema: Bool = false) throws -> HueLight {
        var ct = "null"
        if let ctMin, let ctMax {
            ct = #"{"mirek": 300, "mirek_schema": {"mirek_minimum": \#(ctMin), "mirek_maximum": \#(ctMax)}}"#
        } else if ctCapableNoSchema {
            ct = #"{"mirek": 300}"#
        }
        let json = #"""
        {"id": "\#(id)", "metadata": {"name": "\#(id)", "archetype": null},
         "on": {"on": true}, "dimming": {"brightness": 50},
         "color": null, "color_temperature": \#(ct)}
        """#
        return try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
    }

    /// Mixed CT ranges intersect; the snapshot never fakes 153…500.
    func testMirekRangeIsTheIntersectionOfReadableSchemas() throws {
        let snapshot = CustomizationSnapshotBuilder.snapshot(
            identity: identity(),
            lights: [try light("L1", ctMin: 153, ctMax: 454),
                     try light("L2", ctMin: 200, ctMax: 500)],
            entertainmentAvailable: .known, transport: .bridgeEffectV2, running: true)
        XCTAssertEqual(snapshot.mirekRange?.minMirek, 200)
        XCTAssertEqual(snapshot.mirekRange?.maxMirek, 454)
        XCTAssertEqual(snapshot.colorTemperature.evidence, .known)
    }

    /// A CT-capable light without a readable schema downgrades the evidence
    /// and withholds the range — unknown, never a guessed clamp.
    func testCTCapableWithoutSchemaIsUnreadableNotGuessed() throws {
        let snapshot = CustomizationSnapshotBuilder.snapshot(
            identity: identity(),
            lights: [try light("L1", ctMin: 153, ctMax: 454),
                     try light("L2", ctCapableNoSchema: true)],
            entertainmentAvailable: .known, transport: .bridgeEffectV2, running: true)
        XCTAssertNil(snapshot.mirekRange)
        XCTAssertEqual(snapshot.colorTemperature.evidence, .unreadable)
    }

    /// A failed capability read yields `.unreadable` on every axis — the
    /// resolver then answers unavailable-with-retry instead of standing on
    /// the previous target's stale numbers.
    func testUnreadableSnapshotCarriesUnknownOnEveryAxis() {
        let snapshot = CustomizationSnapshotBuilder.unreadable(
            identity: identity(), totalLights: 3,
            transport: .bridgeEffectV2, running: true)
        for coverage in [snapshot.dimming, snapshot.color, snapshot.colorTemperature,
                         snapshot.gradient, snapshot.effectsV2] {
            XCTAssertEqual(coverage.evidence, .unreadable)
        }
        XCTAssertEqual(snapshot.entertainmentAvailable, .unreadable)

        // And the resolver treats it as unknown — not unsupported.
        let control = CustomizationControlDescriptor(
            id: CustomizationControlID(cardID: "candle", paramID: "warmth"),
            requirement: .colorTemperature)
        let resolution = CustomizationResolver.resolve(control: control, on: snapshot)
        guard case .unavailable(let reason, let remediation) = resolution.availability else {
            return XCTFail("expected unavailable, got \(resolution.availability)")
        }
        XCTAssertEqual(reason, .capabilityUnknown)
        XCTAssertEqual(remediation, .retryCapabilityFetch)
    }

    /// The snapshot's verified-parameter sets come from the profile table,
    /// filtered to what the card declares.
    func testSnapshotVerifiedParametersComeFromTheProfileTable() throws {
        let snapshot = CustomizationSnapshotBuilder.snapshot(
            identity: identity(),
            lights: [try light("L1", ctMin: 153, ctMax: 454)],
            declaredEffectParams: ["candle": ["brightness", "speed", "warmth",
                                              "base_color", "transition"]],
            entertainmentAvailable: .known, transport: .bridgeEffectV2, running: true)
        XCTAssertEqual(snapshot.verifiedEffectParameters["candle"],
                       ["speed", "warmth", "base_color", "transition"])
    }
}
