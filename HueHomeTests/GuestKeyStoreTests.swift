// GuestKeyStoreTests.swift
// ChromaGlow — Family Sharing Phase 2 (guest key custody)
//
// The account-name contract matters as much as the round-trip: the names
// are what GuestProfile.mintedKeyRefs persists and what revocation parses
// back into (profileID, bridgeRecordID). Frozen-surface safety: the
// hue_invite_ prefix can never collide with hue_bridge_<uuid>_* or the
// legacy hue_api_token/hue_bridge_ip slots.

import XCTest
@testable import HueHome

final class GuestKeyStoreTests: XCTestCase {

    private let profileID = "11111111-2222-3333-4444-555555555555"
    private let bridgeID  = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private static let fakeToken = "FAKESTOREDTOKEN-abcdef-FAKESTOREDTOKEN"

    override func tearDown() {
        GuestKeyStore.deleteGuestToken(profileID: profileID, bridgeRecordID: bridgeID)
        super.tearDown()
    }

    func testAccountNameFormatIsExactlyTheDesignedContract() {
        XCTAssertEqual(
            GuestKeyStore.account(profileID: "p1", bridgeRecordID: "b1"),
            "hue_invite_p1_b1_token"
        )
    }

    func testAccountNamesNeverCollideWithFrozenSlots() {
        let name = GuestKeyStore.account(profileID: profileID, bridgeRecordID: bridgeID)
        XCTAssertTrue(name.hasPrefix("hue_invite_"))
        XCTAssertFalse(name.hasPrefix("hue_bridge_"))
        XCTAssertNotEqual(name, "hue_api_token")
        XCTAssertNotEqual(name, "hue_bridge_ip")
        XCTAssertFalse(name.contains(Self.fakeToken), "an account NAME must never embed key material")
    }

    func testSaveLoadDeleteRoundTrip() throws {
        let ref = try GuestKeyStore.saveGuestToken(
            Self.fakeToken, profileID: profileID, bridgeRecordID: bridgeID
        )
        XCTAssertEqual(ref, GuestKeyStore.account(profileID: profileID, bridgeRecordID: bridgeID))
        XCTAssertEqual(
            GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeID),
            Self.fakeToken
        )

        GuestKeyStore.deleteGuestToken(profileID: profileID, bridgeRecordID: bridgeID)
        XCTAssertNil(GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeID))
    }

    func testReMintOverwrites() throws {
        try GuestKeyStore.saveGuestToken("first", profileID: profileID, bridgeRecordID: bridgeID)
        try GuestKeyStore.saveGuestToken("second", profileID: profileID, bridgeRecordID: bridgeID)
        XCTAssertEqual(
            GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeID),
            "second",
            "a re-mint for the same profile+bridge must upsert, not orphan accounts"
        )
    }

    func testDeleteAccountsSweepIgnoresForeignNames() throws {
        try GuestKeyStore.saveGuestToken(
            Self.fakeToken, profileID: profileID, bridgeRecordID: bridgeID
        )
        let ref = GuestKeyStore.account(profileID: profileID, bridgeRecordID: bridgeID)

        // The sweep must refuse to delete anything outside its own prefix —
        // a corrupted mintedKeyRefs list can't be tricked into wiping the
        // owner's real bridge credentials.
        GuestKeyStore.delete(accounts: ["hue_api_token", "hue_bridge_ip", ref])

        XCTAssertNil(GuestKeyStore.loadGuestToken(profileID: profileID, bridgeRecordID: bridgeID))
    }

    func testParseAccountRefRoundTrips() {
        let ref = GuestKeyStore.account(profileID: profileID, bridgeRecordID: bridgeID)
        let parsed = GuestKeyStore.parse(accountRef: ref)
        XCTAssertEqual(parsed?.profileID, profileID)
        XCTAssertEqual(parsed?.bridgeRecordID, bridgeID)

        XCTAssertNil(GuestKeyStore.parse(accountRef: "hue_api_token"))
        XCTAssertNil(GuestKeyStore.parse(accountRef: "hue_invite_only-one-part_token"))
        XCTAssertNil(GuestKeyStore.parse(accountRef: "hue_bridge_x_token"))
    }
}
