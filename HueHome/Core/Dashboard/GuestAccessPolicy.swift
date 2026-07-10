// GuestAccessPolicy.swift
// ChromaGlow — Family Sharing Phase 3 (guest-side enforcement, pure logic)
//
// Every rule the orchestrator's choke point applies lives here, free of
// orchestrator state, so the filter semantics are unit-testable in
// isolation. The choke point itself is applyGuestAccessFilter() in
// UnifiedOrchestrator — it prunes roomsByBridge/zonesByBridge inside
// rebuildAllRooms/rebuildAllZones, so the dashboard, widgets, watch, Siri
// entities, and deep-link resolution all inherit the filter from the one
// place that feeds them.
//
// Semantics (design §5):
//  - No grant for a bridge → passthrough (the owner's own bridges).
//  - A grant with EMPTY allowedGroupIDs → zero groups. Fail closed.
//  - Scenes: a granted bridge shows a scene only when the grant includes
//    the "scenes" feature AND the scene's room survives the group filter.
//  - Enforcement is advisory + local (the key is bridge-wide by platform
//    design) — UI copy states this; the policy just makes the app honest.

import Foundation

enum GuestAccessPolicy {

    /// Filter one bridge's rooms or zones against its grant.
    /// nil grant → untouched. Empty allowlist → [] (fail closed).
    static func filterGroups(
        _ groups: [RoomDisplayItem],
        grant: GuestGrantSnapshot?
    ) -> [RoomDisplayItem] {
        guard let grant else { return groups }
        return groups.filter { grant.allowedGroupIDs.contains($0.id) }
    }

    /// Filter the merged cross-bridge scene list. Scenes on un-granted
    /// bridges pass through; scenes on granted bridges require the
    /// "scenes" feature and an allowed owning room.
    static func filterScenes(
        _ scenes: [GlobalSceneItem],
        grants: [String: GuestGrantSnapshot]
    ) -> [GlobalSceneItem] {
        guard !grants.isEmpty else { return scenes }
        return scenes.filter { scene in
            guard let grant = grants[scene.bridgeID] else { return true }
            return grant.features.contains(GuestFeature.scenes)
                && grant.allowedGroupIDs.contains(scene.roomID)
        }
    }

    /// The feature set the UI should honor for a bridge. Unrestricted when
    /// the bridge has no grant (owner's own) or the id is nil (legacy path
    /// — a grant is always keyed by a real BridgeRecord id, so nil cannot
    /// name a granted bridge).
    static func features(
        for bridgeID: String?,
        grants: [String: GuestGrantSnapshot]
    ) -> GuestFeatureSet {
        guard let bridgeID, let grant = grants[bridgeID] else { return .unrestricted }
        return GuestFeatureSet(features: grant.features)
    }

    /// True when EVERY live bridge is grant-limited — the device is purely
    /// a guest (hide Studio, no scene create anywhere). A device that owns
    /// one bridge and is a guest of another stays false: its own bridges
    /// keep full capability, only the granted bridge's content is limited.
    static func isGuestOnly(
        liveBridgeIDs: some Collection<String>,
        grants: [String: GuestGrantSnapshot]
    ) -> Bool {
        guard !liveBridgeIDs.isEmpty, !grants.isEmpty else { return false }
        return liveBridgeIDs.allSatisfy { grants[$0] != nil }
    }
}
