// BridgeAuthorizationMonitor.swift
// ChromaGlow — Family Sharing Phase 4 (guest-side cooperative wipe signal)
//
// The L-30 pattern (see wc_unpaired in WatchStore/HueHomeApp): active
// wipe happens ONLY on an EXPLICIT bridge refusal, never inferred.
//
// CALLER CONTRACT — reportExplicitUnauthorized may be invoked for exactly
// one class of evidence: the bridge itself answering a data-plane request
// with an authorization refusal (HTTP 401/403 on /clip/v2, or a v1 error
// type 1 body). The data plane rides BridgePinnedTrustDelegate, so an
// on-path attacker cannot forge the signal without the bridge's pinned
// identity. NEVER call this for timeouts, connection failures, DNS
// trouble, or 5xx — transient network pain must not look like
// revocation. SSE reconnect paths are deliberately excluded (their
// failure modes are too noisy to be evidence).
//
// MainTabView consumes the signal: a GRANTED bridge (GuestAccessGrant
// exists) gets the cooperative wipe + a notice; an OWNED bridge only gets
// a re-pair suggestion — an owned credential is never auto-deleted.

import Foundation

@Observable
@MainActor
final class BridgeAuthorizationMonitor {

    static let shared = BridgeAuthorizationMonitor()

    /// Bridges (BridgeRecord.id) with an unconsumed explicit refusal.
    private(set) var unauthorizedBridgeIDs: Set<String> = []
    /// Bumped on EVERY report so observers react even to a repeat of the
    /// same bridge id (a 403 storm collapses into set membership, but the
    /// token still moves).
    private(set) var signalToken: Int = 0

    func reportExplicitUnauthorized(bridgeID: String) {
        unauthorizedBridgeIDs.insert(bridgeID)
        signalToken &+= 1
    }

    func clear(bridgeID: String) {
        unauthorizedBridgeIDs.remove(bridgeID)
    }
}
