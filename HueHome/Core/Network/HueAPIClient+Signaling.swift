// HueAPIClient+Signaling.swift
// ChromaGlow — Round 3 Phase A (full Hue power)
//
// The `signaling` resource field: bridge-native attention flashes. Free
// "flash to identify", notification blinks, and punchBurst — the REST-tier
// punch-pad primitive (2-color alternating flash, no DTLS session needed).
// Signaling self-terminates after `duration`, so a dropped app can never
// leave a light stuck flashing.

import Foundation

// MARK: - SignalingBody

/// PUT /clip/v2/resource/light/{id} (or grouped_light/{id}) → {"signaling": …}
struct SignalingBody: Equatable {
    enum Signal: String {
        case noSignal    = "no_signal"      // cancel early
        case onOff       = "on_off"         // toggle flash
        case onOffColor  = "on_off_color"   // flash to one color (1 color)
        case alternating = "alternating"    // alternate two colors (2 colors)
    }

    /// Bridge cap: 65 534 s.
    static let maxDurationMs = 65_534_000

    var signal: Signal
    var durationMs: Int
    var colorsXY: [CGPoint] = []            // 1 for onOffColor, 2 for alternating

    func dictionary() -> [String: Any] {
        var signaling: [String: Any] = [
            "signal": signal.rawValue,
            "duration": min(Self.maxDurationMs, max(0, durationMs)),
        ]
        if !colorsXY.isEmpty {
            signaling["colors"] = colorsXY.prefix(2).map {
                ["color": ["xy": ["x": Double($0.x), "y": Double($0.y)]]]
            }
        }
        return ["signaling": signaling]
    }

    /// Identify flash: 3 s toggle — the "which light is this?" primitive.
    static func identify() -> SignalingBody {
        SignalingBody(signal: .onOff, durationMs: 3000)
    }

    /// Perform punch pad on the REST tier: a short two-color alternating
    /// burst. Self-terminating, so releasing the pad needs no cleanup PUT.
    static func punchBurst(a: CGPoint, b: CGPoint, durationMs: Int = 2000) -> SignalingBody {
        SignalingBody(signal: .alternating, durationMs: durationMs, colorsXY: [a, b])
    }
}

// MARK: - Client methods

extension HueAPIClient {

    func signalLight(id: String, body: SignalingBody) async throws {
        let (ip, token) = try credentials()
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body.dictionary(), ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) signaling \(body.signal.rawValue)")
    }

    /// grouped_light supports signaling natively — one paced PUT flashes the
    /// whole room (this is a one-shot native field, not an app-driven loop).
    func signalGroupedLight(id: String, body: SignalingBody) async throws {
        let (ip, token) = try credentials()
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body.dictionary(), ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) signaling \(body.signal.rawValue)")
    }
}
