// HueAPIClient.swift
// CastChroma — Story 1.2 / 1.3
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
    private let log = Logger(subsystem: "com.lightshade.app", category: "API")

    // MARK: URLSession (pinned bridge trust — H-01/D-016)
    // BridgePinnedTrustDelegate evaluates the chain and requires the pinned
    // bridge identity on every challenge; it never trust-alls.
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: BridgePinnedTrustDelegate.shared, delegateQueue: nil)
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

    /// Create a v1 API client using the same credentials as this v2 client.
    /// The v1 API uses the same token — it's just placed in the URL path
    /// instead of the hue-application-key header.
    func makeV1Client() throws -> HueV1Client {
        let (ip, token) = try credentials()
        return HueV1Client(ip: ip, token: token)
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
            log.debug("POST /scene body: \(bodyStr)")
        }
        let data = try await execute(req)
        logRaw(data, label: "POST /scene '\(request.metadata.name)'")
    }

    /// Create a new scene and return its bridge-assigned UUID.
    /// Used by BridgeAnimationEngine for v2 dynamic scene uploads.
    func createSceneReturningID(_ request: CreateSceneRequest) async throws -> String {
        let (ip, token) = try credentials()
        var req = try buildRequest(method: "POST", path: "/clip/v2/resource/scene", ip: ip, token: token)
        let encoded = try JSONEncoder().encode(request)
        req.httpBody = encoded
        if let bodyStr = String(data: encoded, encoding: .utf8) {
            log.debug("POST /scene body: \(bodyStr)")
        }
        let data = try await execute(req)
        logRaw(data, label: "POST /scene '\(request.metadata.name)'")

        // Parse response to extract created resource ID
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let rid = first["rid"] as? String else {
            throw HueAPIError.decodingFailed("Cannot extract scene ID from POST response")
        }
        return rid
    }

    /// Activate a scene in dynamic palette mode (bridge cycles through colors autonomously).
    /// The bridge handles all timing — no rules, sensors, or schedules needed.
    ///
    /// - Parameters:
    ///   - id:       Bridge scene UUID.
    ///   - duration: Cycle duration in milliseconds (e.g. 5000 = 5 seconds per transition).
    func activateDynamicScene(id: String, durationMs: Int) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = [
            "recall": [
                "action": "dynamic_palette",
                "duration": durationMs
            ]
        ]
        let data = try await put(
            path: "/clip/v2/resource/scene/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /scene/\(id) dynamic_palette duration=\(durationMs)ms")
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

    /// Rename a scene by updating only its metadata.name field.
    func renameScene(id: String, name: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["metadata": ["name": name]]
        let data = try await put(
            path: "/clip/v2/resource/scene/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /scene/\(id) rename='\(name)'")
    }

    /// Update an existing scene's name and per-light actions.
    /// Used by the Scene Color Builder in edit mode.
    func updateScene(id: String, name: String, actions: [[String: Any]]) async throws {
        let (ip, token) = try credentials()
        var body: [String: Any] = ["actions": actions]
        body["metadata"] = ["name": name]
        let data = try await put(
            path: "/clip/v2/resource/scene/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /scene/\(id) update name='\(name)' actions=\(actions.count)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Room & Zone CRUD
    // ──────────────────────────────────────────────

    /// Rename a room and optionally change its archetype icon.
    /// Hue V2 stores both under /room/{id}/metadata.
    func renameRoom(id: String, name: String, archetype: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["metadata": ["name": name, "archetype": archetype]]
        let data = try await put(
            path: "/clip/v2/resource/room/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /room/\(id) name='\(name)' archetype='\(archetype)'")
    }

    /// Delete a room from the bridge. Lights remain paired — they just leave the room.
    func deleteRoom(id: String) async throws {
        let (ip, token) = try credentials()
        let urlStr = "https://\(ip)/clip/v2/resource/room/\(id)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let data = try await execute(req)
        logRaw(data, label: "DELETE /room/\(id)")
    }

    /// Rename a zone and optionally change its archetype icon.
    func renameZone(id: String, name: String, archetype: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["metadata": ["name": name, "archetype": archetype]]
        let data = try await put(
            path: "/clip/v2/resource/zone/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /zone/\(id) name='\(name)' archetype='\(archetype)'")
    }

    /// Delete a zone from the bridge. Member lights are unaffected.
    func deleteZone(id: String) async throws {
        let (ip, token) = try credentials()
        let urlStr = "https://\(ip)/clip/v2/resource/zone/\(id)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let data = try await execute(req)
        logRaw(data, label: "DELETE /zone/\(id)")
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
        let clamped = (min(100, max(1, brightness))).rounded()
        let body: [String: Any] = ["dimming": ["brightness": clamped]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) brightness=\(Int(clamped))")
    }

    /// Set color temperature (mirek) for all lights in a group.
    /// Mirek range: 153 (cool/6500K) – 500 (warm/2000K).
    func setGroupedLightColorTemp(id: String, mirek: Int) async throws {
        let (ip, token) = try credentials()
        let clamped = min(500, max(153, mirek))
        let body: [String: Any] = ["color_temperature": ["mirek": clamped]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) mirek=\(clamped)")
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

    /// Comprehensive grouped_light effect setter for the Effects engine.
    /// Uses grouped_light/{id} — one call controls all lights in a room simultaneously.
    /// Pass nil for parameters you don't want to change.
    /// `duration` is the transition time in milliseconds (0 = instant).
    func setGroupedLightEffect(
        id:         String,
        on:         Bool?,
        brightness: Double?,
        xy:         (Double, Double)?,
        mirek:      Int?,
        duration:   Int
    ) async throws {
        let (ip, token) = try credentials()
        var body: [String: Any] = [:]
        if let on = on         { body["on"]      = ["on": on] }
        if let b  = brightness { body["dimming"]  = ["brightness": min(100, max(0, b))] }
        if let xy = xy         { body["color"]    = ["xy": ["x": xy.0, "y": xy.1]] }
        if let m  = mirek      { body["color_temperature"] = ["mirek": m] }
        // duration=0 means instant (no fade). Must be sent explicitly.
        body["dynamics"] = ["duration": max(0, duration)]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) effect dur=\(duration)ms")
    }

    /// Fetch light IDs belonging to a specific grouped_light resource.
    /// Resolves the chain: groupedLightID → room/zone → children → light IDs.
    ///
    /// - Rooms have children with rtype "device" — lights are matched via owner.rid.
    /// - Zones have children with rtype "light" — lights are matched by ID directly.
    func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] {
        // Step 1: Find the room or zone that owns this grouped_light
        let rooms = try await fetchRooms()
        let zones = try await fetchZones()

        // Check rooms first (more common), then zones
        if let room = rooms.first(where: { $0.groupedLightID == groupedLightID }) {
            // Room children reference devices (rtype: "device").
            // Lights reference their parent device via owner.rid.
            let deviceIDs = Set(room.children.map { $0.rid })
            let allLights = try await fetchLights()
            let roomLightIDs = allLights
                .filter { light in
                    // Direct light ref (newer firmware) or device-owner ref (older firmware)
                    if room.children.contains(where: { $0.rtype == "light" }) {
                        return deviceIDs.contains(light.id)
                    } else {
                        guard let ownerRID = light.owner?.rid else { return false }
                        return deviceIDs.contains(ownerRID)
                    }
                }
                .map { $0.id }
            return roomLightIDs
        }

        if let zone = zones.first(where: { $0.groupedLightID == groupedLightID }) {
            // Zone children reference lights directly (rtype: "light").
            return zone.children.filter { $0.rtype == "light" }.map { $0.rid }
        }

        // Fallback: grouped_light not found in any room or zone
        // Return empty to avoid affecting wrong lights
        return []
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

    /// Comprehensive single-call light state setter for the Effects engine.
    /// Pass nil for parameters you don't want to change.
    /// `duration` is the transition time in milliseconds (0 = instant).
    func setLightEffect(
        id:         String,
        on:         Bool?,
        brightness: Double?,
        xy:         (Double, Double)?,
        mirek:      Int?,
        duration:   Int
    ) async throws {
        let (ip, token) = try credentials()
        var body: [String: Any] = [:]

        if let on = on         { body["on"]      = ["on": on] }
        if let b  = brightness { body["dimming"]  = ["brightness": min(100, max(0, b))] }
        if let xy = xy         { body["color"]    = ["xy": ["x": xy.0, "y": xy.1]] }
        if let m  = mirek      { body["color_temperature"] = ["mirek": m] }
        if duration > 0        { body["dynamics"] = ["duration": duration] }

        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) effect on=\(String(describing: on)) dur=\(duration)ms")
    }

    /// Set a native bridge effect (colorloop, candle, fire, prism, sparkle, opal, glisten).
    /// These persist on the bridge even after the app closes.
    /// Pass "no_effect" to stop the native effect.
    func setLightNativeEffect(id: String, effect: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["effects": ["effect": effect]]
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) native effect=\(effect)")
    }

    /// Set a native bridge effect on a grouped_light resource.
    /// More reliable than enumerating per-light IDs — grouped_light propagates
    /// the effect field to all compatible lights in the group automatically.
    func setGroupedLightNativeEffect(id: String, effect: String) async throws {
        let (ip, token) = try credentials()
        let body: [String: Any] = ["effects": ["effect": effect]]
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) native effect=\(effect)")
    }

    /// Atomic: set on + effect + brightness in a SINGLE PUT.
    /// Critical for avoiding rate limits — grouped_light allows ~1 PUT/sec.
    /// Combining these fields prevents the bridge from silently dropping commands.
    func setGroupedLightWithEffect(
        id: String, on: Bool, effect: String, brightness: Double? = nil
    ) async throws {
        let (ip, token) = try credentials()
        var body: [String: Any] = [
            "on": ["on": on],
            "effects": ["effect": effect]
        ]
        if let bri = brightness {
            body["dimming"] = ["brightness": max(1, min(100, bri))]
        }
        let data = try await put(
            path: "/clip/v2/resource/grouped_light/\(id)",
            body: body, ip: ip, token: token
        )
        logRaw(data, label: "PUT /grouped_light/\(id) atomic on=\(on) effect=\(effect) bri=\(brightness ?? -1)")
    }

    /// Stop all effects on a light and return to neutral state.
    func stopLightEffects(id: String) async throws {
        try await setLightNativeEffect(id: id, effect: "no_effect")
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

    func post(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        var request = try buildRequest(method: "POST", path: path, ip: ip, token: token)
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
        // L-09: the full URL embeds the bridge LAN IP — log only the resource path.
        log.info("API: \(method, privacy: .public) \(path, privacy: .public)")
        return req
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        let resourcePath = request.url?.path ?? ""
        log.info("API: HTTP \(http.statusCode, privacy: .public) ← \(resourcePath)")
        guard (200...299).contains(http.statusCode) else {
            // Log the bridge's error body BEFORE throwing — it contains the exact reason.
            if let errorBody = String(data: data, encoding: .utf8) {
                log.error("API: Bridge error body: \(errorBody)")
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
            log.error("API: Decode error — \(error.localizedDescription)")
            throw HueAPIError.decodingFailed(error.localizedDescription)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func logRaw(_ data: Data, label: String) {
#if DEBUG
        guard let raw = String(data: data, encoding: .utf8) else { return }
        log.debug("API [\(label)] raw: \(raw)")
        #if DEBUG
        print("[HueAPIClient] \(label) — \(raw)")
        #endif
#endif
    }
}

// The former trust-all HueCertTrustDelegate (evaluated the cert, discarded
// the result, and accepted unconditionally — audit H-01/H-06) was replaced by
// BridgePinnedTrustDelegate in Core/Network/Trust/ (D-016).
