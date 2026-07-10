// GuestRevocationServiceTests.swift
// ChromaGlow — Family Sharing Phase 4 (owner-side revoke)
//
// The invariant: the OWNER-SIDE WIPE ALWAYS HAPPENS — an unreachable
// bridge, refusing firmware, or a verified delete all end with the guest
// key gone from this phone's Keychain, so the QR can never be re-issued.
// Bridge-side outcomes only decide which honesty copy the UI speaks.

import XCTest
@testable import HueHome

@MainActor
final class GuestRevocationServiceTests: XCTestCase {

    private let profileID = "99999999-8888-7777-6666-555555555555"
    private let bridgeA   = "AAAA1111-0000-0000-0000-000000000001"
    private let bridgeB   = "BBBB2222-0000-0000-0000-000000000002"
    private static let tokenA = "FAKEREVOKETOKEN-AAAA"
    private static let tokenB = "FAKEREVOKETOKEN-BBBB"

    override func tearDown() {
        GuestKeyStore.deleteGuestToken(profileID: profileID, bridgeRecordID: bridgeA)
        GuestKeyStore.deleteGuestToken(profileID: profileID, bridgeRecordID: bridgeB)
        super.tearDown()
    }

    private func seedKeys() throws -> [String] {
        [
            try GuestKeyStore.saveGuestToken(Self.tokenA, profileID: profileID, bridgeRecordID: bridgeA),
            try GuestKeyStore.saveGuestToken(Self.tokenB, profileID: profileID, bridgeRecordID: bridgeB),
        ]
    }

    func testUnreachableBridgeStillWipesLocalKeys() async throws {
        let refs = try seedKeys()

        let report = await GuestRevocationService.revoke(
            profileID: profileID,
            mintedKeyRefs: refs,
            deleteOnBridge: { _, _ in .bridgeUnreachable }
        )

        XCTAssertEqual(report.perBridge[bridgeA], .bridgeUnreachable)
        XCTAssertEqual(report.perBridge[bridgeB], .bridgeUnreachable)
        XCTAssertNil(GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeA),
                     "the local wipe must not depend on the bridge answering")
        XCTAssertNil(GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeB))
        XCTAssertFalse(report.fullyRevokedEverywhere)
    }

    func testVerifiedDeleteReportsFullyRevoked() async throws {
        let refs = try seedKeys()
        var deletedTokens: [String] = []

        let report = await GuestRevocationService.revoke(
            profileID: profileID,
            mintedKeyRefs: refs,
            deleteOnBridge: { _, token in
                deletedTokens.append(token)
                return .revokedOnBridge
            }
        )

        XCTAssertTrue(report.fullyRevokedEverywhere)
        XCTAssertEqual(Set(deletedTokens), [Self.tokenA, Self.tokenB],
                       "the delete must target the guest's own tokens as elements")
        XCTAssertNil(GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeA))
    }

    func testMixedOutcomesAreNotFullyRevoked() async throws {
        let refs = try seedKeys()

        let report = await GuestRevocationService.revoke(
            profileID: profileID,
            mintedKeyRefs: refs,
            deleteOnBridge: { bridgeRecordID, _ in
                bridgeRecordID == self.bridgeA
                    ? .revokedOnBridge
                    : .localOnly(reason: "DELETE not available")
            }
        )

        XCTAssertEqual(report.perBridge[bridgeA], .revokedOnBridge)
        XCTAssertEqual(report.perBridge[bridgeB], .localOnly(reason: "DELETE not available"))
        XCTAssertFalse(report.fullyRevokedEverywhere)
    }

    func testForeignAndMalformedRefsAreIgnored() async throws {
        let refs = try seedKeys()
        var bridgeCalls = 0

        let report = await GuestRevocationService.revoke(
            profileID: profileID,
            mintedKeyRefs: refs + [
                "hue_api_token",                                   // frozen slot — never touched
                "hue_invite_OTHERPROFILE_\(bridgeA)_token",        // someone else's profile
                "garbage",
            ],
            deleteOnBridge: { _, _ in bridgeCalls += 1; return .revokedOnBridge }
        )

        XCTAssertEqual(bridgeCalls, 2, "only this profile's well-formed refs may act")
        XCTAssertEqual(report.perBridge.count, 2)
    }

    func testMissingStoredKeyIsLocalOnlyWithoutBridgeCall() async {
        // Ref exists but the Keychain no longer holds the token (already
        // wiped once) — nothing to delete bridge-side, no call made.
        var bridgeCalls = 0
        let report = await GuestRevocationService.revoke(
            profileID: profileID,
            mintedKeyRefs: [GuestKeyStore.account(profileID: profileID, bridgeRecordID: bridgeA)],
            deleteOnBridge: { _, _ in bridgeCalls += 1; return .revokedOnBridge }
        )

        XCTAssertEqual(bridgeCalls, 0)
        guard case .localOnly = report.perBridge[bridgeA] else {
            return XCTFail("expected localOnly, got \(String(describing: report.perBridge[bridgeA]))")
        }
    }
}
