// GuestInviteSpec.swift
// ChromaGlow — Family Sharing Phase 2/3 seam
//
// What the mint flow needs to know about a guest profile — handed over by
// ProfilesAccessView ("Generate Invite" on a GuestProfile) or, until that
// UI lands, the DEBUG More row. Deliberately a value type: the mint sheet
// never touches the SwiftData model; the CALLER owns writing back
// lastInviteAt and mintedKeyRefs via onMinted.

import Foundation

struct GuestInviteSpec: Identifiable {
    /// GuestProfile.id — keys the hue_invite_<profileID>_<bridgeRecordID>_token accounts.
    let profileID: String
    let profileName: String
    /// Flat cross-bridge group allowlist (GuestProfile.allowedGroupIDs);
    /// the mint sheet intersects it with each bridge's own groups.
    let allowedGroupIDs: [String]
    /// GuestFeature strings to grant.
    let features: [String]
    /// A revoked profile must never re-show or re-mint a QR (design §4).
    let isRevoked: Bool

    var id: String { profileID }
}
