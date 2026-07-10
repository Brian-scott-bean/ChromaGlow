// GuestAccessModelsTests.swift
// ChromaGlow — Family Sharing Phase 3 (SwiftData models + grant store)
//
// Uses an in-memory container with the FULL production schema list — this
// guards against "model referenced but not registered in HueHomeApp's
// Schema" crashes, which only surface at container-open time.

import XCTest
import SwiftData
@testable import HueHome

@MainActor
final class GuestAccessModelsTests: XCTestCase {

    var container: ModelContainer!
    var context:   ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        // Mirror HueHomeApp.swift's Schema EXACTLY (plus in-memory config).
        let schema = Schema([
            BridgeRecord.self,
            HueLocalRoom.self,
            HueLocalScene.self,
            EffectPreset.self,
            FavouriteColor.self,
            ActivityEvent.self,
            EnergySnapshot.self,
            AppSettings.self,
            AppAutomation.self,
            GuestProfile.self,
            GuestAccessGrant.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context   = ModelContext(container)
    }

    override func tearDown() async throws {
        context   = nil
        container = nil
        try await super.tearDown()
    }

    // ── GuestProfile ──────────────────────────────────────

    func testProfileDefaultsAndRoundTrip() throws {
        let profile = GuestProfile(name: "Alex")
        context.insert(profile)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<GuestProfile>()).first)
        XCTAssertEqual(fetched.name, "Alex")
        XCTAssertEqual(fetched.icon, "person.fill")
        XCTAssertEqual(fetched.features, GuestFeature.all)
        XCTAssertTrue(fetched.allowedGroupIDs.isEmpty)
        XCTAssertTrue(fetched.mintedKeyRefs.isEmpty)
        XCTAssertNil(fetched.revokedAt)
        XCTAssertNil(fetched.lastInviteAt)
    }

    func testProfileStoresGrantsAndKeyRefs() throws {
        let profile = GuestProfile(
            name: "Sam",
            allowedGroupIDs: ["room-1", "zone-9"],
            features: [GuestFeature.onOff, GuestFeature.scenes]
        )
        profile.mintedKeyRefs = ["hue_invite_p1_b1_token"]
        profile.lastInviteAt = Date(timeIntervalSince1970: 1_780_000_000)
        context.insert(profile)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<GuestProfile>()).first)
        XCTAssertEqual(fetched.allowedGroupIDs, ["room-1", "zone-9"])
        XCTAssertEqual(fetched.features, [GuestFeature.onOff, GuestFeature.scenes])
        XCTAssertEqual(fetched.mintedKeyRefs, ["hue_invite_p1_b1_token"])
    }

    // ── GuestAccessGrantStore ─────────────────────────────

    func testUpsertInsertsThenOverwritesOnReScan() throws {
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "bridge-1",
            allowedGroupIDs: ["a"],
            features: [GuestFeature.onOff],
            grantedProfileName: "Alex",
            modelContext: context
        )
        // A newer invite for the SAME bridge — the documented update path.
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "bridge-1",
            allowedGroupIDs: ["a", "b"],
            features: GuestFeature.all,
            grantedProfileName: "Alex",
            modelContext: context
        )

        let all = try GuestAccessGrantStore.allGrants(modelContext: context)
        XCTAssertEqual(all.count, 1, "re-scan must upsert, never duplicate")
        XCTAssertEqual(Set(all[0].allowedGroupIDs), ["a", "b"])
        XCTAssertEqual(Set(all[0].features), Set(GuestFeature.all))
    }

    func testGrantForBridgeFetchesExactMatch() throws {
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "bridge-1", allowedGroupIDs: ["a"],
            features: GuestFeature.all, grantedProfileName: "Alex",
            modelContext: context
        )
        XCTAssertNotNil(try GuestAccessGrantStore.grant(for: "bridge-1", modelContext: context))
        XCTAssertNil(try GuestAccessGrantStore.grant(for: "bridge-2", modelContext: context))
    }

    func testDeleteGrantRemovesIt() throws {
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "bridge-1", allowedGroupIDs: ["a"],
            features: GuestFeature.all, grantedProfileName: "Alex",
            modelContext: context
        )
        try GuestAccessGrantStore.deleteGrant(for: "bridge-1", modelContext: context)
        XCTAssertTrue(try GuestAccessGrantStore.allGrants(modelContext: context).isEmpty)
    }

    func testPruneOrphansKeepsLiveAndDisabledBridges() throws {
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "live-bridge", allowedGroupIDs: ["a"],
            features: GuestFeature.all, grantedProfileName: "Alex",
            modelContext: context
        )
        try GuestAccessGrantStore.upsert(
            bridgeRecordID: "removed-bridge", allowedGroupIDs: ["b"],
            features: GuestFeature.all, grantedProfileName: "Alex",
            modelContext: context
        )

        let pruned = try GuestAccessGrantStore.pruneOrphans(
            liveBridgeIDs: ["live-bridge"], modelContext: context
        )

        XCTAssertEqual(pruned, 1)
        let remaining = try GuestAccessGrantStore.allGrants(modelContext: context)
        XCTAssertEqual(remaining.map(\.bridgeRecordID), ["live-bridge"])
    }

    // ── Snapshot conversion ───────────────────────────────

    func testSnapshotMirrorsGrant() {
        let grant = GuestAccessGrant(
            bridgeRecordID: "b1",
            allowedGroupIDs: ["a", "b", "a"],   // duplicate collapses in the Set
            features: [GuestFeature.brightness],
            grantedProfileName: "Alex"
        )
        let snap = GuestGrantSnapshot(from: grant)
        XCTAssertEqual(snap.allowedGroupIDs, ["a", "b"])
        XCTAssertEqual(snap.features, [GuestFeature.brightness])
        XCTAssertEqual(snap.profileName, "Alex")

        let features = GuestFeatureSet(features: snap.features)
        XCTAssertFalse(features.canPower)
        XCTAssertTrue(features.canAdjust)
        XCTAssertFalse(features.canRecallScenes)
    }
}
