// BridgeAPIClient.swift
// CastChroma — Stage 2A Multi-Bridge
//
// A named HueAPIClient with explicit credentials (ip + token) and
// bridge identity metadata. One instance lives per registered bridge
// inside UnifiedOrchestrator.
//
// Uses HueAPIClient(ip:token:) init — no subclassing required.

import Foundation

/// A HueAPIClient pre-configured with a specific bridge's credentials.
/// Adds bridgeID and bridgeName identity for orchestrator bookkeeping.
final class BridgeAPIClient: HueAPIClient, @unchecked Sendable {

    let bridgeID:   String
    let bridgeName: String

    init(bridgeID: String, bridgeName: String, ip: String, token: String) {
        self.bridgeID   = bridgeID
        self.bridgeName = bridgeName
        super.init(ip: ip, token: token)
    }
}
