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

class HueAPIClient: @unchecked Sendable {

    // MARK: Singleton (single-bridge legacy path)
    static let shared = HueAPIClient()

    // MARK: Explicit credentials (multi-bridge path — set in init, never nil if provided)
    private let explicitIP:    String?
    private let explicitToken: String?

    /// Legacy init — reads credentials from Keychain via `credentials()`.
    init() {
        explicitIP    = nil
        explicitToken = nil
    }

    /// Multi-bridge init — uses explicit credentials, no Keychain read needed.
    init(ip: String, token: String) {
        explicitIP    = ip
        explicitToken = token
    }

    // MARK: Logger
    private let log = Logger(subsystem: "com.huehome.pro", category: "API")

    // MARK: URLSession (cert-trust for Hue self-signed)
    // certDelegate retained explicitly — URLSession holds a strong ref internally
    // but this makes ownership unambiguous and survives lazy initialization.
    private let certDelegate = HueCertTrustDelegate()
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self.certDelegate, delegateQueue: nil)
    }()

    // ──────────────────────────────────────────────
    // MARK: - Bootstrap
    // ──────────────────────────────────────────────

    /// Returns (ip, token). Uses explicit values if set, otherwise reads from Keychain.
    func credentials() throws -> (ip: String, token: String) {
        if let ip = explicitIP, let token = explicitToken,
           !ip.isEmpty, !token.isEmpty {
            return (ip, token)
        }
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

    func fetchZones() async throws -> [HueZone] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/zone", ip: ip, token: token)
        logRaw(data, label: "GET /zone")
        return try decode(HueV2Response<HueZone>.self, from: data).data
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
    /// Activate a scene on the Bridge.
    ///
    /// - Parameters:
    ///   - id:        Bridge scene UUID.
    ///   - speed:     Optional dynamics speed (0.0–1.0). Only meaningful for dynamic
    ///                palette scenes; ignored by the Bridge for static scenes.
    func activateScene(id: String, speed: Double? = nil) async throws {
        let (ip, token) = try credentials()
        var recall: [String: Any] = ["action": "active"]
        if let speed {
            // Clamp to valid range — Bridge rejects values outside [0, 1].
            recall["dynamics"] = ["speed": min(max(speed, 0.0), 1.0)]
        }
        let body: [String: Any] = ["recall": recall]
        let data = try await put(
            path: "/clip/v2/resource/scene/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /scene/\(id) speed=\(speed.map { String(format: "%.2f", $0) } ?? "default")")
    }

    /// Create a new scene on the Bridge with the given name and per-light actions.
    func createScene(_ request: CreateSceneRequest) async throws {
        let (ip, token) = try credentials()
        var req = try buildRequest(method: "POST", path: "/clip/v2/resource/scene", ip: ip, token: token)
        let encoded = try JSONEncoder().encode(request)
        req.httpBody = encoded
        // Log outgoing body for debugging — remove noisy on-disk logging once stable.
        if let bodyStr = String(data: encoded, encoding: .utf8) {
            log.debug("POST /scene body: \(bodyStr, privacy: .public)")
        }
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
    // MARK: - Devices (/clip/v2/resource/device)
    // ──────────────────────────────────────────────

    /// Raw Data so the caller can do resilient per-item parsing.
    /// GET /clip/v2/resource/device returns all paired devices:
    /// bulbs, sensors, buttons, the bridge itself.
    func fetchDevicesRaw() async throws -> Data {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/device", ip: ip, token: token)
        logRaw(data, label: "GET /device")
        return data
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

    /// Fetch a single grouped_light by ID.
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

    /// Fetch ALL grouped lights in a single request — O(1) vs N fetchGroupedLight calls.
    /// Use this in loadAll() to avoid N+1 network fetches per room.
    func fetchGroupedLights() async throws -> [HueGroupedLight] {
        let (ip, token) = try credentials()
        let data = try await get(path: "/clip/v2/resource/grouped_light", ip: ip, token: token)
        logRaw(data, label: "GET /grouped_light")
        return try decode(HueV2Response<HueGroupedLight>.self, from: data).data
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

    func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        let (ip, token) = try credentials()
        let clamped = (min(100, max(1, brightness))).rounded()   // round to avoid float noise in logs
        let body: [String: Any] = ["dimming": ["brightness": clamped]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) brightness=\(Int(clamped))")
    }

    /// Set on-state + brightness in a single PUT for a grouped_light — avoids the two-call flash
    /// where lights turn on at old brightness before new brightness is applied.
    func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        let (ip, token) = try credentials()
        let clamped = (min(100, max(1, brightness))).rounded()
        let body: [String: Any] = [
            "on":      ["on": on],
            "dimming": ["brightness": clamped],
        ]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) on=\(on) brightness=\(Int(clamped))")
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

    /// Set on-state + brightness in a single PUT — avoids the two-call flash.
    /// Use instead of setLight + setLightBrightness when both values need updating.
    func setLightState(id: String, on: Bool, brightness: Double) async throws {
        let (ip, token) = try credentials()
        let clamped = min(100, max(1, brightness))
        let body: [String: Any] = [
            "on":      ["on": on],
            "dimming": ["brightness": clamped],
        ]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) on=\(on) brightness=\(clamped)")
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
            // Log the bridge's error body BEFORE throwing — it contains the exact reason.
            if let errorBody = String(data: data, encoding: .utf8) {
                log.error("API: Bridge error body: \(errorBody, privacy: .public)")
            }
            throw HueAPIError.httpError(http.statusCode)
        }
        return data
    }

    // ──────────────────────────────────────────────
    // MARK: - Decoding
    // ──────────────────────────────────────────────

    private static let sharedDecoder = JSONDecoder()

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.sharedDecoder.decode(type, from: data)
        } catch {
            log.error("API: Decode error — \(error.localizedDescription, privacy: .public)")
            throw HueAPIError.decodingFailed(error.localizedDescription)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func logRaw(_ data: Data, label: String) {
#if DEBUG
        guard let raw = String(data: data, encoding: .utf8) else { return }
        log.debug("API [\(label, privacy: .public)] raw: \(raw, privacy: .public)")
        #if DEBUG
        print("[HueAPIClient] \(label) — \(raw)")
        #endif
#endif
    }
}

// MARK: - Cert Trust Delegate

/// Accepts the Hue Bridge self-signed certificate for both session-level and
/// task-level auth challenges.
///
/// Why both levels?
/// - `URLSessionDelegate` handles server-level challenges (TLS handshake at session open time)
/// - `URLSessionTaskDelegate` handles task-level challenges — on iOS 15+, `URLSession.data(for:)`
///   and `URLSession.bytes(for:)` route HTTPS certificate challenges HERE, not to the session delegate.
///   Without this, all API calls and SSE streams fail with -1202 on self-signed Hue Bridge certs.
final class HueCertTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - Shared logic

    private func acceptBridgeCert(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Evaluate with error suppressed — we intentionally trust the Bridge's self-signed cert.
        var cfError: CFError?
        _ = SecTrustEvaluateWithError(serverTrust, &cfError)
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    // MARK: - URLSessionDelegate (session-level, TLS handshake)

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptBridgeCert(challenge, completionHandler: completionHandler)
    }

    // MARK: - URLSessionTaskDelegate (task-level, iOS 15+ data/bytes tasks)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        acceptBridgeCert(challenge, completionHandler: completionHandler)
    }
}
