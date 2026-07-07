// HueAPIClient+Gradient.swift
// ChromaGlow — Round 3 Phase A (full Hue power)
//
// gradient.points: gradient-capable lights (Play gradient strip, Signe,
// gradient lightstrip) accept up to 5 CIE points over plain REST — the
// bridge interpolates them along the strip. This is what lets compositions
// render ALONG a strip on the REST tier (Phase F's GradientChannelMap).

import Foundation

// MARK: - GradientBody

/// PUT /clip/v2/resource/light/{id} → {"gradient": {"points": …}}
struct GradientBody: Equatable {
    /// Bridge caps gradient points at 5; a body needs at least 2.
    static let maxPoints = 5

    var pointsXY: [CGPoint]
    var mode: String? = nil                 // e.g. "interpolated_palette"
    // Composition-frame extras: one PUT carries the whole strip state.
    var brightness: Double? = nil
    var on: Bool? = nil
    var durationMs: Int? = nil

    func dictionary() -> [String: Any] {
        // The bridge rejects fewer than 2 points — pad by repeating the last
        // (a single color is a valid degenerate gradient).
        var points = Array(pointsXY.prefix(Self.maxPoints))
        while points.count < 2, let last = points.last { points.append(last) }
        var gradient: [String: Any] = [
            "points": points.map {
                ["color": ["xy": ["x": Double($0.x), "y": Double($0.y)]]]
            }
        ]
        if let mode { gradient["mode"] = mode }
        var body: [String: Any] = ["gradient": gradient]
        if let on { body["on"] = ["on": on] }
        if let brightness {
            body["dimming"] = ["brightness": min(100, max(1, brightness))]
        }
        if let durationMs { body["dynamics"] = ["duration": max(0, durationMs)] }
        return body
    }
}

// MARK: - Client methods

extension HueAPIClient {

    /// Paint up to 5 gradient points along a gradient-capable light.
    func setLightGradient(id: String, body: GradientBody) async throws {
        let (ip, token) = try credentials()
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body.dictionary(), ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) gradient ×\(body.pointsXY.count)")
    }
}
