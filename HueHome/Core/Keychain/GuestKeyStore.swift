// GuestKeyStore.swift
// ChromaGlow — Family Sharing Phase 2 (owner-side guest key custody)
//
// Additive Keychain accounts for per-guest minted application keys:
//   "hue_invite_<profileID>_<bridgeRecordID>_token"
// (the exact names from the design doc §5 — no existing key is renamed,
// and the prefix can never collide with hue_bridge_<uuid>_* or the legacy
// hue_api_token/hue_bridge_ip slots).
//
// Everything rides KeychainManager's generic save/load/delete so the
// D-018 attribute contract (service com.lightshade.app, shared access
// group, AfterFirstUnlockThisDeviceOnly, non-synchronizable) is inherited
// from the one place that defines it. Values are never logged — account
// NAMES are safe (no secret material), key material is not.

import Foundation

enum GuestKeyStore {

    /// "hue_invite_<profileID>_<bridgeRecordID>_token" — also what
    /// GuestProfile.mintedKeyRefs stores, so revocation can find every key
    /// a profile was ever issued.
    static func account(profileID: String, bridgeRecordID: String) -> String {
        "hue_invite_\(profileID)_\(bridgeRecordID)_token"
    }

    /// Reverse of `account(profileID:bridgeRecordID:)` — used by revocation
    /// to route each stored ref back to its bridge. Returns nil for
    /// anything that isn't a well-formed guest-key account name.
    static func parse(accountRef: String) -> (profileID: String, bridgeRecordID: String)? {
        guard accountRef.hasPrefix("hue_invite_"), accountRef.hasSuffix("_token") else { return nil }
        let core = accountRef.dropFirst("hue_invite_".count).dropLast("_token".count)
        // Both ids are UUID strings (36 chars, no underscores) joined by "_".
        let parts = core.split(separator: "_")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Save (or overwrite — a re-mint for the same profile+bridge upserts,
    /// so no orphan accounts accumulate). Returns the account name for
    /// GuestProfile.mintedKeyRefs.
    @discardableResult
    static func saveGuestToken(_ token: String, profileID: String, bridgeRecordID: String) throws -> String {
        let name = account(profileID: profileID, bridgeRecordID: bridgeRecordID)
        try KeychainManager.shared.save(value: token, for: name)
        return name
    }

    static func loadGuestToken(profileID: String, bridgeRecordID: String) -> String? {
        try? KeychainManager.shared.load(
            for: account(profileID: profileID, bridgeRecordID: bridgeRecordID)
        )
    }

    static func deleteGuestToken(profileID: String, bridgeRecordID: String) {
        try? KeychainManager.shared.delete(
            for: account(profileID: profileID, bridgeRecordID: bridgeRecordID)
        )
    }

    /// Revocation sweep — delete every stored ref (best-effort; missing
    /// accounts are fine).
    static func delete(accounts: [String]) {
        for name in accounts where name.hasPrefix("hue_invite_") {
            try? KeychainManager.shared.delete(for: name)
        }
    }
}
