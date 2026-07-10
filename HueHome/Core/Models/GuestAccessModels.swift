// GuestAccessModels.swift
// ChromaGlow — Family Sharing Phase 3 (Profiles & Access)
//
// Two ADDITIVE SwiftData models (new tables only — a Build-21 TestFlight
// upgrade is a lightweight migration, nothing existing changes):
//
//  - GuestProfile (OWNER device): who the owner invited, which rooms and
//    features they granted, and the Keychain account names of the keys
//    minted for that profile. Deleting/revoking marks `revokedAt` so the
//    mint sheet can refuse to re-show a QR.
//  - GuestAccessGrant (GUEST device): what this phone was granted, keyed
//    by BridgeRecord.id. A BridgeRecord is NEVER mutated by sharing —
//    the grant rides alongside it (design §5).
//
// Enforcement is app-side only and the UI must say so: the key itself can
// control the whole bridge from any Hue app — a Philips Hue platform fact.
//
// Design: docs/ios/profiles-access-share-invite-design-2026-07.md §5.

import Foundation
import SwiftData

// MARK: - Feature vocabulary

/// The granted-feature strings as they travel in invites and persist in
/// models. String-typed (not an enum) so an older app receiving a future
/// feature it doesn't know simply doesn't grant it — fail closed.
enum GuestFeature {
    static let onOff      = "onOff"
    static let brightness = "brightness"
    static let scenes     = "scenes"
    static let all: [String] = [onOff, brightness, scenes]
}

// MARK: - Owner side

@Model
final class GuestProfile {
    @Attribute(.unique) var id: String     // UUID string
    var name:     String
    var icon:     String                   // SF Symbol name
    var colorHex: String
    /// v2 group UUIDs (rooms/zones) across all bridges. Globally unique per
    /// the Hue CLIP v2 id space, so one flat list is unambiguous.
    var allowedGroupIDs: [String]
    /// GuestFeature strings this profile is granted.
    var features: [String]
    var createdAt:    Date
    var lastInviteAt: Date?
    /// Set when the owner revokes — the profile stays (auditable, refuses
    /// re-invite) rather than vanishing.
    var revokedAt:    Date?
    /// Keychain account names ("hue_invite_<profileID>_<bridgeRecordID>_token")
    /// of keys minted for this profile. Written by the mint flow; consumed
    /// by revocation. Never the key material itself.
    var mintedKeyRefs: [String]

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "person.fill",
        colorHex: String = "#FFB000",
        allowedGroupIDs: [String] = [],
        features: [String] = GuestFeature.all
    ) {
        self.id              = id
        self.name            = name
        self.icon            = icon
        self.colorHex        = colorHex
        self.allowedGroupIDs = allowedGroupIDs
        self.features        = features
        self.createdAt       = Date()
        self.lastInviteAt    = nil
        self.revokedAt       = nil
        self.mintedKeyRefs   = []
    }
}

// MARK: - Guest side

@Model
final class GuestAccessGrant {
    /// == BridgeRecord.id of the granted bridge. One grant per bridge; a
    /// re-scanned newer invite upserts (that IS the documented update path —
    /// no owner→guest channel exists).
    @Attribute(.unique) var bridgeRecordID: String
    var allowedGroupIDs: [String]
    var features: [String]
    var grantedProfileName: String
    var receivedAt: Date

    init(
        bridgeRecordID: String,
        allowedGroupIDs: [String],
        features: [String],
        grantedProfileName: String,
        receivedAt: Date = Date()
    ) {
        self.bridgeRecordID     = bridgeRecordID
        self.allowedGroupIDs    = allowedGroupIDs
        self.features           = features
        self.grantedProfileName = grantedProfileName
        self.receivedAt         = receivedAt
    }
}

// MARK: - Value snapshots (orchestrator-side)

/// Value copy of a GuestAccessGrant — the orchestrator never holds @Model
/// objects (SwiftData object threading hazards); it snapshots these in
/// updateGuestGrants and filters against them.
struct GuestGrantSnapshot: Equatable, Sendable {
    let allowedGroupIDs: Set<String>
    let features: Set<String>
    let profileName: String

    init(allowedGroupIDs: Set<String>, features: Set<String>, profileName: String) {
        self.allowedGroupIDs = allowedGroupIDs
        self.features        = features
        self.profileName     = profileName
    }

    init(from grant: GuestAccessGrant) {
        self.allowedGroupIDs = Set(grant.allowedGroupIDs)
        self.features        = Set(grant.features)
        self.profileName     = grant.grantedProfileName
    }
}

/// Guest-state summary for the UI shell (banner, tab gating). The
/// orchestrator recomputes this whenever grants or clients change; views
/// observe it instead of running their own @Query over GuestAccessGrant.
struct GuestAccessInfo: Equatable, Sendable {
    /// At least one LIVE bridge is grant-limited → show the guest banner.
    let hasAnyGrant: Bool
    /// EVERY live bridge is grant-limited → hide Studio, no scene create.
    let isGuestOnly: Bool
    /// Distinct granted profile names, for the banner detail sheet.
    let profileNames: [String]

    static let none = GuestAccessInfo(hasAnyGrant: false, isGuestOnly: false, profileNames: [])
}

/// What the UI may show/do for one bridge. `.unrestricted` for the owner's
/// own bridges (no grant), demo mode, and nil bridge ids (legacy paths).
struct GuestFeatureSet: Equatable, Sendable {
    let canPower:        Bool
    let canAdjust:       Bool   // brightness AND color/CT — "adjust light state"
    let canRecallScenes: Bool

    static let unrestricted = GuestFeatureSet(canPower: true, canAdjust: true, canRecallScenes: true)

    init(canPower: Bool, canAdjust: Bool, canRecallScenes: Bool) {
        self.canPower        = canPower
        self.canAdjust       = canAdjust
        self.canRecallScenes = canRecallScenes
    }

    /// Fail closed: only the features the grant names are enabled.
    init(features: Set<String>) {
        self.canPower        = features.contains(GuestFeature.onOff)
        self.canAdjust       = features.contains(GuestFeature.brightness)
        self.canRecallScenes = features.contains(GuestFeature.scenes)
    }
}

// MARK: - Grant store (the guest-side write/read seam)

/// The API the invite accept flow calls to persist a grant, and configure()
/// reads to snapshot them. Static funcs on a ModelContext — no singleton
/// state, trivially testable with an in-memory container.
///
/// Accept-flow ordering contract (no flash of forbidden rooms): verify
/// identity → Keychain token → BridgePairingRegistrar.register →
/// GuestAccessGrantStore.upsert → orchestrator.updateGuestGrants →
/// orchestrator.addBridge → loadAll.
@MainActor
enum GuestAccessGrantStore {

    /// Insert-or-update the grant for a bridge. Re-scanning a newer invite
    /// for the same bridge lands here and overwrites — the documented
    /// "change what a guest can access" path.
    @discardableResult
    static func upsert(
        bridgeRecordID: String,
        allowedGroupIDs: [String],
        features: [String],
        grantedProfileName: String,
        receivedAt: Date = Date(),
        modelContext: ModelContext
    ) throws -> GuestAccessGrant {
        if let existing = try grant(for: bridgeRecordID, modelContext: modelContext) {
            existing.allowedGroupIDs    = allowedGroupIDs
            existing.features           = features
            existing.grantedProfileName = grantedProfileName
            existing.receivedAt         = receivedAt
            try modelContext.save()
            return existing
        }
        let grant = GuestAccessGrant(
            bridgeRecordID: bridgeRecordID,
            allowedGroupIDs: allowedGroupIDs,
            features: features,
            grantedProfileName: grantedProfileName,
            receivedAt: receivedAt
        )
        modelContext.insert(grant)
        try modelContext.save()
        return grant
    }

    static func grant(for bridgeRecordID: String, modelContext: ModelContext) throws -> GuestAccessGrant? {
        var descriptor = FetchDescriptor<GuestAccessGrant>(
            predicate: #Predicate { $0.bridgeRecordID == bridgeRecordID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func allGrants(modelContext: ModelContext) throws -> [GuestAccessGrant] {
        try modelContext.fetch(FetchDescriptor<GuestAccessGrant>())
    }

    static func deleteGrant(for bridgeRecordID: String, modelContext: ModelContext) throws {
        guard let grant = try grant(for: bridgeRecordID, modelContext: modelContext) else { return }
        modelContext.delete(grant)
        try modelContext.save()
    }

    /// Remove grants whose bridge no longer exists (bridge removed while a
    /// grant referenced it). Uses ALL BridgeRecord ids — a temporarily
    /// DISABLED bridge keeps its grant.
    @discardableResult
    static func pruneOrphans(liveBridgeIDs: Set<String>, modelContext: ModelContext) throws -> Int {
        let all = try allGrants(modelContext: modelContext)
        let orphans = all.filter { !liveBridgeIDs.contains($0.bridgeRecordID) }
        guard !orphans.isEmpty else { return 0 }
        for orphan in orphans { modelContext.delete(orphan) }
        try modelContext.save()
        return orphans.count
    }
}
