// SignalingService.swift
// ChromaGlow — Round 3 Phase D (full Hue power)
//
// Thin @MainActor service over the bridge's signaling field: "flash to
// identify" for lights/rooms and punchBurst — the REST-tier punch-pad
// primitive Perform uses when no DTLS session exists. Every call is one
// gate-paced PUT and the flash self-terminates on the bridge, so there is
// nothing to cancel and a killed app can never leave a light stuck.

import Foundation
import CoreGraphics

@MainActor
struct SignalingService {

    let orchestrator: UnifiedOrchestrator

    /// 3-second identify flash on one light ("which bulb is this?").
    @discardableResult
    func identifyLight(id: String, bridgeID: String?) async -> Bool {
        guard let api = orchestrator.hueClient(for: bridgeID) else { return false }
        let gate = orchestrator.commandGate(for: bridgeID)
        let error = await gate.send(retry: false) {
            try await api.signalLight(id: id, body: .identify())
        }
        return error == nil
    }

    /// Identify a whole room/zone via its grouped light — one paced PUT.
    @discardableResult
    func identifyRoom(_ room: RoomDisplayItem) async -> Bool {
        guard let groupedLightID = room.groupedLightID,
              let api = orchestrator.hueClient(for: room.bridgeID) else { return false }
        let gate = orchestrator.commandGate(for: room.bridgeID)
        let error = await gate.send(retry: false) {
            try await api.signalGroupedLight(id: groupedLightID, body: .identify())
        }
        return error == nil
    }

    /// Perform punch pad on the REST tier: two-color alternating burst on
    /// the whole room in one paced PUT (no DTLS session required).
    @discardableResult
    func punchBurst(room: RoomDisplayItem,
                    a: CGPoint, b: CGPoint,
                    durationMs: Int = 2000) async -> Bool {
        guard let groupedLightID = room.groupedLightID,
              let api = orchestrator.hueClient(for: room.bridgeID) else { return false }
        let gate = orchestrator.commandGate(for: room.bridgeID)
        let error = await gate.send(retry: false) {
            try await api.signalGroupedLight(
                id: groupedLightID,
                body: .punchBurst(a: a, b: b, durationMs: durationMs))
        }
        return error == nil
    }
}
