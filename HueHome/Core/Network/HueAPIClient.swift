// HueAPIClient.swift
// HueHome Pro — Story 1.2 / 1.3
//
// Stateless V2 REST client for the Philips Hue Bridge.
// All requests go to https://{ip}/clip/v2/... with the stored Application Key header.
// Uses the same self-signed cert trust strategy as the pairing handshake.
//
// Design: pure async functions that throw — no Combine, no state.
// The ViewModel owns state; this client is a pure I/O layer.

import Foundation
import OSLog

// MARK: - HueAPIError

enum HueAPIError: LocalizedError {
    case missingCredentials
    case badURL(String)
    case httpError(Int)
    case decodingFailed(String)
    case bridgeError([String])

    var errorDescription: String? {
        switch self {
        case .missingCredentials:         return "No Bridge IP or API token found in Keychain."
        case .badURL(let s):              return "Malformed URL: \(s)"
        case .httpError(let code):        return "HTTP \(code) from Bridge."
        case .decodingFailed(let msg):    return "Decode failed: \(msg)"
        case .bridgeError(let msgs):      return "Bridge errors: \(msgs.joined(separator: ", "))"
        }
    }
}

// MARK: - HueAPIClient

final class HueAPIClient: @unchecked Sendable {

    // MARK: Singleton
    static let shared = HueAPIClient()
    init() {}   // internal so tests can instantiate directly too

    // MARK: Logger
    private let log = Logger(subsystem: "com.huehome.pro", category: "API")

    // MARK: URLSession (cert-trust for Hue self-signed)
    private lazy var session: URLSession = {
        let delegate = HueCertTrustDelegate()
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()

    // ──────────────────────────────────────────────
    // MARK: - Bootstrap
    // ──────────────────────────────────────────────

    /// Load Bridge IP + token from Keychain. Throws HueAPIError.missingCredentials if either is absent.
    func credentials() throws -> (ip: String, token: String) {
        guard let ip    = try? KeychainManager.shared.loadBridgeIP(),
              let token = try? KeychainManager.shared.loadAPIToken(),
              !ip.isEmpty, !token.isEmpty else {
            throw HueAPIError.missingCredentials
        }
        return (ip, token)
    }

    // ──────────────────────────────────────────────
    // MARK: - GET Resources
    // ──────────────────────────────────────────────

    func fetchRooms() async throws -> [HueRoom] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/room", ip: ip, token: token)
        logRaw(data, label: "GET /room")
        return try decode(HueV2Response<HueRoom>.self, from: data).data
    }

    func fetchLights() async throws -> [HueLight] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/light", ip: ip, token: token)
        logRaw(data, label: "GET /light")
        return try decode(HueV2Response<HueLight>.self, from: data).data
    }

    func fetchScenes() async throws -> [HueScene] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/scene", ip: ip, token: token)
        logRaw(data, label: "GET /scene")
        return try decode(HueV2Response<HueScene>.self, from: data).data
    }

    /// Activate a scene by its V2 resource UUID.
    func activateScene(id: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["recall": ["action": "active"]]
        let data = try await put(
            path: "/clip/v2/resource/scene/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /scene/\(id) recall=active")
    }

    /// Create a new scene on the Bridge with the given name and per-light actions.
    func createScene(_ request: CreateSceneRequest) async throws {
        let (ip, token) = try credentials()
        var req = try buildRequest(method: "POST", path: "/clip/v2/resource/scene", ip: ip, token: token)
        req.httpBody = try JSONEncoder().encode(request)
        let data = try await execute(req)
        logRaw(data, label: "POST /scene '\(request.metadata.name)'")
    }

    /// Delete a scene by its V2 resource UUID.
    func deleteScene(id: String) async throws {
        let (ip, token) = try credentials()
        let urlStr = "https://\(ip)/clip/v2/resource/scene/\(id)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let data = try await execute(req)
        logRaw(data, label: "DELETE /scene/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Automations (behavior_instance)
    // ──────────────────────────────────────────────

    func fetchAutomations() async throws -> [HueBehaviorInstance] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/behavior_instance", ip: ip, token: token)
        logRaw(data, label: "GET /behavior_instance")
        return try decode(HueV2Response<HueBehaviorInstance>.self, from: data).data
    }

    /// Returns raw Data so the caller can do its own resilient per-item decoding.
    func fetchAutomationsRaw() async throws -> Data {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/behavior_instance", ip: ip, token: token)
        logRaw(data, label: "GET /behavior_instance (raw)")
        return data
    }

    func setAutomation(id: String, enabled: Bool) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["enabled": enabled]
        let data = try await put(
            path: "/clip/v2/resource/behavior_instance/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /behavior_instance/\(id) enabled=\(enabled)")
    }

    func fetchGroupedLight(id: String) async throws -> HueGroupedLight {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/grouped_light/\(id)", ip: ip, token: token)
        logRaw(data, label: "GET /grouped_light/\(id)")
        let response = try decode(HueV2Response<HueGroupedLight>.self, from: data)
        guard let first = response.data.first else {
            throw HueAPIError.decodingFailed("Empty grouped_light response for id \(id)")
        }
        return first
    }

    // ──────────────────────────────────────────────
    // MARK: - PUT Control
    // ──────────────────────────────────────────────

    /// Toggle a room's lights on or off via its grouped_light resource.
    func setGroupedLight(id: String, on: Bool) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["on": ["on": on]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) on=\(on)")
    }

    /// Set brightness (0–100) for a grouped_light resource.
    func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        let (ip, token) = try credentials()
        let clamped = min(100, max(1, brightness))   // Bridge rejects 0; use on=false instead
        let body: [String: Any] = ["dimming": ["brightness": clamped]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) brightness=\(clamped)")
    }

    /// Toggle an individual light on or off.
    func setLight(id: String, on: Bool) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["on": ["on": on]]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) on=\(on)")
    }

    /// Set brightness (1–100) for an individual light.
    func setLightBrightness(id: String, brightness: Double) async throws {
        let (ip, token) = try credentials()
        let clamped = min(100, max(1, brightness))
        let body: [String: Any] = ["dimming": ["brightness": clamped]]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) brightness=\(clamped)")
    }

    /// Set colour (CIE 1931 xy) for a colour-capable light.
    func setLightColor(id: String, x: Double, y: Double) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["color": ["xy": ["x": x, "y": y]]]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) color.xy=(\(String(format: "%.3f", x)),\(String(format: "%.3f", y)))")
    }

    /// Set colour temperature (in mirek) for a colour-temp-capable light.
    func setLightColorTemp(id: String, mirek: Int) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["color_temperature": ["mirek": mirek]]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) mirek=\(mirek)")
    }


    // ──────────────────────────────────────────────
    // MARK: - Private HTTP
    // ──────────────────────────────────────────────

    func get(path: String, ip: String, token: String) async throws -> Data {
        let request = try buildRequest(method: "GET", path: path, ip: ip, token: token)
        return try await execute(request)
    }

    func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        var request = try buildRequest(method: "PUT", path: path, ip: ip, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(request)
    }

    private func buildRequest(method: String, path: String, ip: String, token: String) throws -> URLRequest {
        let urlStr = "https://\(ip)\(path)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        log.info("API: \(method) \(urlStr, privacy: .public)")
        return req
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        log.info("API: HTTP \(http.statusCode, privacy: .public) ← \(request.url?.path ?? "", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            throw HueAPIError.httpError(http.statusCode)
        }
        return data
    }

    // ──────────────────────────────────────────────
    // MARK: - Decoding
    // ──────────────────────────────────────────────

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            return decoded
        } catch {
            log.error("API: Decode error — \(error.localizedDescription, privacy: .public)")
            throw HueAPIError.decodingFailed(error.localizedDescription)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func logRaw(_ data: Data, label: String) {
        guard let raw = String(data: data, encoding: .utf8) else { return }
        log.debug("API [\(label, privacy: .public)] raw: \(raw, privacy: .public)")
        print("[HueAPIClient] \(label) — \(raw)")
    }
}

// MARK: - Cert Trust Delegate

/// Accepts the Hue Bridge self-signed certificate on local network.
final class HueCertTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
