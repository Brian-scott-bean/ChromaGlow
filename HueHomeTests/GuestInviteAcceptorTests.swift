// GuestInviteAcceptorTests.swift
// ChromaGlow — Family Sharing Phase 2 (guest accept engine)
//
// The gate is pure and tested in isolation; the accept flow runs against
// an in-memory ModelContainer with both live probes stubbed (URLProtocol
// cannot present a server trust, so identity is seam-injected, exactly
// like the pairing VM's pinAcquisitionOverride).
//
// The invariant that matters most here: every refusal path persists
// NOTHING (no BridgeRecord, no credentials) — a hostile or stale QR can
// only produce a refusal.

import XCTest
import SwiftData
@testable import HueHome

@MainActor
final class GuestInviteAcceptorTests: XCTestCase {

    private static let fakeToken = "FAKEACCEPTTOKEN-abcdef0123456789-FAKEACCEPT"
    private let bid = "ECB5FAFFFE99AA01"
    private let pinPK = "cGlubmVkLWtleS1oYXNoLWZvci10ZXN0cw=="

    var container: ModelContainer!
    var context:   ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([
            BridgeRecord.self, HueLocalRoom.self, HueLocalScene.self,
            EffectPreset.self, FavouriteColor.self, ActivityEvent.self,
            EnergySnapshot.self, AppSettings.self, AppAutomation.self,
            GuestProfile.self, GuestAccessGrant.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context   = ModelContext(container)
    }

    override func tearDown() async throws {
        // Remove anything an accept persisted into the REAL keychain/pin store.
        for record in (try? context.fetch(FetchDescriptor<BridgeRecord>())) ?? [] {
            KeychainManager.shared.deleteCredentials(for: record.id)
        }
        BridgePinStore.shared.removePin(bridgeID: bid)
        context = nil
        container = nil
        try await super.tearDown()
    }

    // ── Fixtures ──────────────────────────────────────────

    private func grant(expiresAt: Date = Date().addingTimeInterval(900),
                       token: String = GuestInviteAcceptorTests.fakeToken) -> SharedBridgeInviteGrant {
        SharedBridgeInviteGrant(
            bid: bid, host: "192.0.2.44", port: 443, name: "Test Bridge",
            pinPK: pinPK, token: token,
            allowedGroups: ["room-a", "zone-z"],
            features: [GuestFeature.onOff, GuestFeature.scenes],
            expiresAt: expiresAt
        )
    }

    private func capture(pin: String? = nil, bridgeID: String? = nil) -> PairingLeafCapture {
        PairingLeafCapture(
            bridgeID: bridgeID ?? bid,
            publicKeySHA256: pin ?? pinPK,
            certSHA256: "Y2VydC1oYXNo",
            caValidated: false
        )
    }

    /// Acceptor whose probes succeed by default.
    private func makeAcceptor(
        identity: GuestInviteAcceptor.IdentityProbe?? = nil,
        token: GuestInviteAcceptor.TokenProbe = .authorized
    ) -> (acceptor: GuestInviteAcceptor, identityCalls: () -> Int) {
        let acceptor = GuestInviteAcceptor()
        var calls = 0
        acceptor.identityProbeOverride = { [self] _ in
            calls += 1
            if let identity { return identity }   // explicit override (incl. nil)
            return GuestInviteAcceptor.IdentityProbe(configBridgeID: bid, capture: capture())
        }
        acceptor.tokenProbeOverride = { _ in token }
        return (acceptor, { calls })
    }

    private func recordCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<BridgeRecord>())) ?? -1
    }

    // ── The pure gate ─────────────────────────────────────

    func testGateAcceptsMatchingTriple() {
        XCTAssertTrue(GuestInviteAcceptor.validateInviteCapture(
            capture: capture(), configBridgeID: bid, grant: grant(), existingPin: nil))
    }

    func testGateRefusesConfigMismatch() {
        XCTAssertFalse(GuestInviteAcceptor.validateInviteCapture(
            capture: capture(), configBridgeID: "ECB5FAFFFE000000", grant: grant(),
            existingPin: nil))
    }

    func testGateRefusesForeignBridgeAnswering() {
        // Leaf + config agree with each other but not with the QR.
        let foreign = "ECB5FAFFFE000000"
        XCTAssertFalse(GuestInviteAcceptor.validateInviteCapture(
            capture: capture(bridgeID: foreign), configBridgeID: foreign, grant: grant(),
            existingPin: nil))
    }

    func testGateRefusesPinMismatch() {
        XCTAssertFalse(GuestInviteAcceptor.validateInviteCapture(
            capture: capture(pin: "ZGlmZmVyZW50LWtleQ=="), configBridgeID: bid,
            grant: grant(), existingPin: nil))
    }

    func testGateNeverOverwritesADifferingStoredPin() {
        // A stored pin for this bridgeid that differs from the live capture
        // is the MITM signal — even a QR that matches the live capture must
        // refuse rather than displace existing trust.
        let stored = BridgePin(bridgeID: bid, publicKeySHA256: "c3RvcmVkLW90aGVy",
                               certSHA256: "eA==", host: "192.0.2.44", pinnedAt: Date())
        XCTAssertFalse(GuestInviteAcceptor.validateInviteCapture(
            capture: capture(), configBridgeID: bid, grant: grant(), existingPin: stored))
    }

    // ── Accept flow ───────────────────────────────────────

    func testExpiredInviteRefusesBeforeAnyNetwork() async {
        let (acceptor, identityCalls) = makeAcceptor()
        let expired = grant(expiresAt: Date().addingTimeInterval(
            -(InvitePayloadCodec.acceptSkewGrace + 60)))

        let outcome = await acceptor.accept(grant: expired, profileName: "Alex",
                                            modelContext: context)

        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(identityCalls(), 0, "expiry must refuse before touching the network")
        XCTAssertEqual(recordCount(), 0)
    }

    func testUnreachableIdentityProbePersistsNothing() async {
        let (acceptor, _) = makeAcceptor(identity: .some(nil))

        let outcome = await acceptor.accept(grant: grant(), profileName: "Alex",
                                            modelContext: context)

        XCTAssertEqual(outcome, .bridgeUnreachable)
        XCTAssertEqual(recordCount(), 0)
        XCTAssertNil(BridgePinStore.shared.pin(forBridgeID: bid))
    }

    func testIdentityMismatchPersistsNothing() async {
        let (acceptor, _) = makeAcceptor(identity: GuestInviteAcceptor.IdentityProbe(
            configBridgeID: bid, capture: capture(pin: "ZXZpbC1icmlkZ2Uta2V5")))

        let outcome = await acceptor.accept(grant: grant(), profileName: "Alex",
                                            modelContext: context)

        XCTAssertEqual(outcome, .identityMismatch)
        XCTAssertEqual(recordCount(), 0)
        XCTAssertNil(BridgePinStore.shared.pin(forBridgeID: bid),
                     "a refused capture must never be pinned")
    }

    func testRevokedBeforeAcceptPersistsNoCredentials() async {
        let (acceptor, _) = makeAcceptor(token: .unauthorized)
        var seedFired = false
        acceptor.onGrantEstablished = { _ in seedFired = true }

        let outcome = await acceptor.accept(grant: grant(), profileName: "Alex",
                                            modelContext: context)

        XCTAssertEqual(outcome, .revokedBeforeAccept)
        XCTAssertEqual(recordCount(), 0)
        XCTAssertFalse(seedFired)
        // The pin IS persisted by design — it equals the owner's verified
        // pin by gate construction, so it is correct regardless of outcome.
        XCTAssertNotNil(BridgePinStore.shared.pin(forBridgeID: bid))
    }

    func testHappyPathJoinsMintsRecordAndFiresGrantSeed() async throws {
        let (acceptor, _) = makeAcceptor()
        var seed: GuestGrantSeed?
        acceptor.onGrantEstablished = { seed = $0 }

        let outcome = await acceptor.accept(grant: grant(), profileName: "Alex",
                                            modelContext: context)

        guard case .joined(let recordID) = outcome else {
            return XCTFail("expected joined, got \(outcome)")
        }
        let records = try context.fetch(FetchDescriptor<BridgeRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, recordID)
        XCTAssertEqual(records[0].bridgeIdentifier, bid)

        let creds = try KeychainManager.shared.loadCredentials(for: recordID)
        XCTAssertEqual(creds.token, Self.fakeToken)
        XCTAssertNil(KeychainManager.shared.loadClientKey(for: recordID),
                     "a guest credential must never include a clientkey")

        let firedSeed = try XCTUnwrap(seed)
        XCTAssertEqual(firedSeed.bridgeRecordID, recordID)
        XCTAssertEqual(firedSeed.allowedGroupIDs, ["room-a", "zone-z"])
        XCTAssertEqual(firedSeed.grantedProfileName, "Alex")
        XCTAssertNotNil(BridgePinStore.shared.pin(forBridgeID: bid))
    }

    func testReScanIsIdempotentAndUpdatesTheGrant() async throws {
        let (acceptor, _) = makeAcceptor()
        var seeds: [GuestGrantSeed] = []
        acceptor.onGrantEstablished = { seed in
            seeds.append(seed)
            // Mirror the view's wiring so the second pass sees a grant.
            try? GuestAccessGrantStore.upsert(
                bridgeRecordID: seed.bridgeRecordID,
                allowedGroupIDs: seed.allowedGroupIDs,
                features: seed.features,
                grantedProfileName: seed.grantedProfileName,
                modelContext: self.context
            )
        }

        let first = await acceptor.accept(grant: grant(), profileName: "Alex",
                                          modelContext: context)
        guard case .joined = first else { return XCTFail("first accept failed: \(first)") }

        let second = await acceptor.accept(grant: grant(), profileName: "Alex",
                                           modelContext: context)
        guard case .joined = second else { return XCTFail("re-scan refused: \(second)") }

        XCTAssertEqual(recordCount(), 1, "registrar dedup must keep exactly one record")
        XCTAssertEqual(seeds.count, 2, "the update path re-fires the grant seed")
        XCTAssertEqual(
            (try GuestAccessGrantStore.allGrants(modelContext: context)).count, 1
        )
    }

    func testOwnFullPairingIsNeverDowngraded() async throws {
        // Simulate the owner's phone: a record with full credentials
        // (clientkey present) and NO guest grant.
        let ownID = UUID().uuidString
        try KeychainManager.shared.saveCredentials(
            ip: "192.0.2.44", token: "owners-own-full-token",
            clientKey: "AABBCCDD", for: ownID
        )
        defer { KeychainManager.shared.deleteCredentials(for: ownID) }
        let own = BridgeRecord(id: ownID, name: "Mine", host: "192.0.2.44",
                               bridgeIdentifier: bid)
        context.insert(own)
        try context.save()

        let (acceptor, identityCalls) = makeAcceptor()
        let outcome = await acceptor.accept(grant: grant(), profileName: "Alex",
                                            modelContext: context)

        XCTAssertEqual(outcome, .alreadyConnected)
        XCTAssertEqual(identityCalls(), 0, "the guard must refuse before any network")
        let creds = try KeychainManager.shared.loadCredentials(for: ownID)
        XCTAssertEqual(creds.token, "owners-own-full-token",
                       "a guest token must never replace an owned credential")
    }
}
