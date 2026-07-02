// HueIntentAPIClient.swift
// CastChroma — Siri Shortcuts
//
// Lightweight PUT-capable client used exclusively by AppIntents.
// Reads bridge IP + token from WidgetDataStore (App Group UserDefaults)
// so it works from both the main app process and the Siri extension process.
// Uses the same TLS trust-all delegate as WidgetAPIClient.

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
