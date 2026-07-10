// HueIntentAPIClient.swift
// ChromaGlow — Siri Shortcuts
//
// Lightweight PUT-capable client used exclusively by AppIntents. Callers
// read bridge IP + token from WidgetDataStore so it works in a background
// intent launch with no configured orchestrator. Unlike the widget's
// fire-and-forget BridgeWriter, every sender here THROWS — Siri owes the
// user an honest failure dialog. Body builders are pure and unit-tested.

import Foundation

enum HueIntentAPIClient {

    // MARK: - Shared Session (pinned bridge trust — M-01/D-016)

    private static let session: URLSession = {
        URLSession(configuration: .default,
                   delegate: BridgePinnedTrustDelegate.shared,
                   delegateQueue: nil)
    }()

    // MARK: - Grouped Light Control

    /// Turn a room's grouped light on or off.
    static func setGroupedLight(id: String, on: Bool, ip: String, token: String) async throws {
        let body: [String: Any] = ["on": ["on": on]]
        try await put(path: "/clip/v2/resource/grouped_light/\(id)", body: body, ip: ip, token: token)
    }

    /// Set a room's brightness (1–100%).
    static func setGroupedLight(id: String, brightness: Double, ip: String, token: String) async throws {
        let clamped = min(100, max(1, brightness))
        let body: [String: Any] = [
            "on":      ["on": true],
            "dimming": ["brightness": clamped]
        ]
        try await put(path: "/clip/v2/resource/grouped_light/\(id)", body: body, ip: ip, token: token)
    }

    /// Set a room's color (CIE xy). 400ms transition so a spoken command
    /// glides instead of snapping.
    static func setGroupedLightColor(id: String, x: Double, y: Double, ip: String, token: String) async throws {
        try await put(path: "/clip/v2/resource/grouped_light/\(id)",
                      body: colorBody(x: x, y: y), ip: ip, token: token)
    }

    /// Set a room's white color temperature (mirek).
    static func setGroupedLightColorTemp(id: String, mirek: Int, ip: String, token: String) async throws {
        try await put(path: "/clip/v2/resource/grouped_light/\(id)",
                      body: colorTempBody(mirek: mirek), ip: ip, token: token)
    }

    /// One preset write (Energize/Read/Relax/Sleep) to one group.
    static func applyPreset(_ preset: LightingPreset, to id: String, ip: String, token: String) async throws {
        try await put(path: "/clip/v2/resource/grouped_light/\(id)",
                      body: presetBody(brightness: preset.brightness, mirek: preset.mirek),
                      ip: ip, token: token)
    }

    /// Kill any bridge-persistent native effect (candle/fire/…) on a group.
    /// `no_effect` is the one effects value grouped_light accepts.
    static func stopNativeEffects(id: String, ip: String, token: String) async throws {
        try await put(path: "/clip/v2/resource/grouped_light/\(id)",
                      body: stopEffectsBody, ip: ip, token: token)
    }

    // MARK: - Scene Recall

    /// Recall a scene — mirrors HueAPIClient.activateScene / BridgeWriter.
    static func recallScene(id: String, ip: String, token: String) async throws {
        try await put(path: "/clip/v2/resource/scene/\(id)",
                      body: ["recall": ["action": "active"]], ip: ip, token: token)
    }

    // MARK: - Pure body builders (unit-tested)

    static func colorBody(x: Double, y: Double) -> [String: Any] {
        [
            "on":       ["on": true],
            "color":    ["xy": ["x": x, "y": y]],
            "dynamics": ["duration": 400],
        ]
    }

    static func colorTempBody(mirek: Int) -> [String: Any] {
        [
            "on":                ["on": true],
            "color_temperature": ["mirek": min(500, max(153, mirek))],
            "dynamics":          ["duration": 400],
        ]
    }

    /// Same shape the widget's ApplyPresetIntent sends (800ms glide).
    static func presetBody(brightness: Double, mirek: Int) -> [String: Any] {
        [
            "on":                ["on": true],
            "dimming":           ["brightness": brightness],
            "color_temperature": ["mirek": mirek],
            "dynamics":          ["duration": 800],
        ]
    }

    static var stopEffectsBody: [String: Any] {
        ["effects": ["effect": "no_effect"]]
    }

    // MARK: - Private PUT helper

    private static func put(path: String, body: [String: Any], ip: String, token: String) async throws {
        guard let url = URL(string: "https://\(ip)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(token,               forHTTPHeaderField: "hue-application-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
