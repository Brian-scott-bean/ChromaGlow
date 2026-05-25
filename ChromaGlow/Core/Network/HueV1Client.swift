// HueV1Client.swift
// ChromaGlow — Bridge-Stored Animations
//
// Lightweight Hue API v1 REST client for bridge-stored animation resources.
// Uses the SAME authentication token as v2, just placed in the URL path
// instead of the hue-application-key header.
//
// v1 endpoint: https://{ip}/api/{token}/...
// v2 endpoint: https://{ip}/clip/v2/...  (with hue-application-key header)
//
// The v1 API exposes schedules, rules, and CLIP sensors that v2 does not,
// enabling self-looping animations that run on the bridge firmware itself.

import Foundation
import OSLog

// MARK: - Bridge Resource Capacity

struct BridgeResourceCapacity {
    let rulesUsed: Int
    let rulesTotal: Int       // ~250
    let sensorsUsed: Int
    let sensorsTotal: Int     // ~250
    let schedulesUsed: Int
    let schedulesTotal: Int   // ~100
    let scenesUsed: Int
    let scenesTotal: Int      // ~200

    var rulesAvailable: Int { rulesTotal - rulesUsed }
    var sensorsAvailable: Int { sensorsTotal - sensorsUsed }
    var schedulesAvailable: Int { schedulesTotal - schedulesUsed }
    var scenesAvailable: Int { scenesTotal - scenesUsed }

    /// Whether there's room for at least one 8-step animation
    /// (needs ~10 rules, 1 sensor, 1 schedule, 8 scenes)
    var canFitOneAnimation: Bool {
        rulesAvailable >= 12 &&
        sensorsAvailable >= 2 &&
        schedulesAvailable >= 2 &&
        scenesAvailable >= 10
    }
}

// MARK: - HueV1Client

class HueV1Client: @unchecked Sendable {

    private let ip: String
    let token: String  // Internal: used by BridgeAnimationEngine for rule action paths
    private let log = Logger(subsystem: "com.chromaglow.app", category: "V1API")

    /// Expose bridge IP for manifest storage.
    var bridgeIP: String { ip }

    // Reuse the same cert-trust delegate as HueAPIClient
    private let certDelegate = HueCertTrustDelegate()
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self.certDelegate, delegateQueue: nil)
    }()

    init(ip: String, token: String) {
        self.ip = ip
        self.token = token
    }

    // ──────────────────────────────────────────────
    // MARK: - Base URL
    // ──────────────────────────────────────────────

    private var baseURL: String { "https://\(ip)/api/\(token)" }

    // ──────────────────────────────────────────────
    // MARK: - CLIP Sensors
    // ──────────────────────────────────────────────

    /// Create a CLIPGenericStatus sensor on the bridge.
    /// Used as a step counter for animation rule chains.
    /// Returns the bridge-assigned sensor ID (numeric string).
    func createCLIPSensor(name: String, initialStatus: Int = 0) async throws -> String {
        let body: [String: Any] = [
            "name": name,
            "type": "CLIPGenericStatus",
            "modelid": "CGANIM",
            "manufacturername": "ChromaGlow",
            "swversion": "1.0",
            "uniqueid": UUID().uuidString,
            "state": ["status": initialStatus]
        ]
        let result = try await post(path: "/sensors", body: body)
        return try extractCreatedID(from: result)
    }

    /// Update the sensor's status value.
    func setSensorStatus(id: String, status: Int) async throws {
        let body: [String: Any] = ["status": status]
        _ = try await put(path: "/sensors/\(id)/state", body: body)
    }

    /// Delete a sensor.
    func deleteSensor(id: String) async throws {
        _ = try await delete(path: "/sensors/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Rules
    // ──────────────────────────────────────────────

    /// Create a rule on the bridge.
    /// Conditions and actions use v1 address format: "/sensors/{id}/state/status"
    /// Returns the bridge-assigned rule ID.
    func createRule(
        name: String,
        conditions: [[String: Any]],
        actions: [[String: Any]]
    ) async throws -> String {
        let body: [String: Any] = [
            "name": String(name.prefix(32)),  // v1 name limit
            "conditions": conditions,
            "actions": actions
        ]
        let result = try await post(path: "/rules", body: body)
        return try extractCreatedID(from: result)
    }

    /// Delete a rule.
    func deleteRule(id: String) async throws {
        _ = try await delete(path: "/rules/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Schedules
    // ──────────────────────────────────────────────

    /// Create a recurring schedule that fires every `interval` seconds.
    /// The command is executed each time the timer fires.
    /// Returns the bridge-assigned schedule ID.
    func createRecurringSchedule(
        name: String,
        intervalSeconds: Int,
        command: [String: Any],
        autoDelete: Bool = false
    ) async throws -> String {
        // ISO 8601 duration: PT00:00:05 = 5 seconds
        let hours = intervalSeconds / 3600
        let minutes = (intervalSeconds % 3600) / 60
        let seconds = intervalSeconds % 60
        let timeStr = "R/PT\(String(format: "%02d", hours)):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"

        let body: [String: Any] = [
            "name": String(name.prefix(32)),
            "command": command,
            // Use only 'localtime' — bridge rejects schedules that set both
            // 'time' and 'localtime' simultaneously (error 703).
            "localtime": timeStr,
            // NOTE: Do NOT include 'autodelete' — bridge firmware rejects it
            // with error type 6 ("parameter not available"). Omitting it
            // defaults to false (schedule persists until manually deleted).
            "status": "enabled"
        ]
        let result = try await post(path: "/schedules", body: body)
        return try extractCreatedID(from: result)
    }

    /// Enable or disable a schedule.
    func setScheduleEnabled(id: String, enabled: Bool) async throws {
        let body: [String: Any] = ["status": enabled ? "enabled" : "disabled"]
        _ = try await put(path: "/schedules/\(id)", body: body)
    }

    /// Delete a schedule.
    func deleteSchedule(id: String) async throws {
        _ = try await delete(path: "/schedules/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Scenes (v1 format)
    // ──────────────────────────────────────────────

    /// Create a v1 scene with per-light states.
    /// `lightstates` maps light ID → state dict (on, bri, xy, transitiontime).
    /// Returns the bridge-assigned scene ID.
    func createScene(
        name: String,
        lightIDs: [String],
        lightstates: [String: [String: Any]],
        recycle: Bool = false
    ) async throws -> String {
        let body: [String: Any] = [
            "name": String(name.prefix(32)),
            "lights": lightIDs,
            "lightstates": lightstates,
            "recycle": recycle
        ]
        let result = try await post(path: "/scenes", body: body)
        return try extractCreatedID(from: result)
    }

    /// Delete a scene.
    func deleteScene(id: String) async throws {
        _ = try await delete(path: "/scenes/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Resourcelinks
    // ──────────────────────────────────────────────

    /// Create a resourcelink that groups related resources for easy cleanup.
    /// `links` should be v1 paths like "/sensors/42", "/rules/13", etc.
    func createResourcelink(
        name: String,
        description: String = "ChromaGlow bridge animation",
        links: [String]
    ) async throws -> String {
        let body: [String: Any] = [
            "name": String(name.prefix(32)),
            "description": description,
            "classid": 1,  // app-defined
            "recycle": false,
            "links": links
        ]
        let result = try await post(path: "/resourcelinks", body: body)
        return try extractCreatedID(from: result)
    }

    /// Delete a resourcelink (does NOT delete linked resources).
    func deleteResourcelink(id: String) async throws {
        _ = try await delete(path: "/resourcelinks/\(id)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Resource Capacity
    // ──────────────────────────────────────────────

    /// Fetch current resource usage to check if the bridge has room
    /// for another animation rule chain.
    func fetchResourceCapacity() async throws -> BridgeResourceCapacity {
        // v1 /config endpoint includes resource counts
        let configData = try await get(path: "/config")
        // Also count existing resources
        let rulesData = try await get(path: "/rules")
        let sensorsData = try await get(path: "/sensors")
        let schedulesData = try await get(path: "/schedules")
        let scenesData = try await get(path: "/scenes")

        let rulesCount = countTopLevelKeys(in: rulesData)
        let sensorsCount = countTopLevelKeys(in: sensorsData)
        let schedulesCount = countTopLevelKeys(in: schedulesData)
        let scenesCount = countTopLevelKeys(in: scenesData)

        return BridgeResourceCapacity(
            rulesUsed: rulesCount,
            rulesTotal: 250,
            sensorsUsed: sensorsCount,
            sensorsTotal: 250,
            schedulesUsed: schedulesCount,
            schedulesTotal: 100,
            scenesUsed: scenesCount,
            scenesTotal: 200
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Group Actions (for scene activation)
    // ──────────────────────────────────────────────

    /// Activate a v1 scene on a group.
    /// Used internally by rules — this returns the command dict
    /// for embedding in rule actions.
    func sceneActivationCommand(groupID: String, sceneID: String) -> [String: Any] {
        return [
            "address": "/groups/\(groupID)/action",  // RELATIVE path — bridge resolves user context internally
            "method": "PUT",
            "body": ["scene": sceneID]
        ]
    }

    /// Build a **rule action** dict for incrementing the CLIP sensor status.
    /// Rule actions use RELATIVE paths — the bridge resolves the user context internally.
    func sensorIncrementCommand(sensorID: String, nextStatus: Int) -> [String: Any] {
        return [
            "address": "/sensors/\(sensorID)/state",  // relative — correct for rule actions
            "method": "PUT",
            "body": ["status": nextStatus]
        ]
    }

    /// Build a **schedule command** dict for incrementing the CLIP sensor status.
    /// Schedule commands require the FULL path including `/api/{token}/` —
    /// unlike rule actions, the bridge does NOT append user context for schedules.
    func sensorIncrementScheduleCommand(sensorID: String, nextStatus: Int) -> [String: Any] {
        return [
            "address": "/api/\(token)/sensors/\(sensorID)/state",  // full path — required for schedule commands
            "method": "PUT",
            "body": ["status": nextStatus]
        ]
    }

    // ──────────────────────────────────────────────
    // MARK: - Groups (v1)
    // ──────────────────────────────────────────────

    /// Fetch v1 groups to find the group ID that matches a v2 room.
    /// v1 groups use numeric IDs; we match by name or light membership.
    func fetchGroups() async throws -> Data {
        return try await get(path: "/groups")
    }

    /// Find the v1 group ID for a set of v1 numeric light IDs.
    /// Returns "0" (all lights) as fallback if no match found.
    func findGroupID(containingLights lightIDs: [String]) async throws -> String {
        let data = try await fetchGroups()
        guard let groups = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return "0"
        }
        for (groupID, group) in groups {
            if let lights = group["lights"] as? [String] {
                let groupSet = Set(lights)
                let targetSet = Set(lightIDs)
                if targetSet.isSubset(of: groupSet) {
                    return groupID
                }
            }
        }
        return "0"  // fallback: all lights group
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch All (for purge/cleanup)
    // ──────────────────────────────────────────────

    func fetchSchedules() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/schedules")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
    }

    func fetchRules() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/rules")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
    }

    func fetchSensors() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/sensors")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
    }

    func fetchScenes() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/scenes")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
    }

    func fetchResourcelinks() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/resourcelinks")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
    }

    // ──────────────────────────────────────────────
    // MARK: - Lights (v1 → v2 ID mapping)
    // ──────────────────────────────────────────────

    /// Fetch all v1 lights. Returns dict of numeric ID → light object.
    func fetchLights() async throws -> [String: [String: Any]] {
        let data = try await get(path: "/lights")
        guard let lights = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return lights
    }

    /// Convert v2 UUID light IDs to v1 numeric IDs.
    /// v1 lights have a "uniqueid" field that can be matched to v2 UUIDs
    /// via the v2 `id_v1` field, OR we match by name/uniqueid patterns.
    ///
    /// If the input IDs are already numeric (v1 format), returns them as-is.
    func resolveV1LightIDs(from v2LightIDs: [String]) async throws -> [String] {
        // Check if these are already v1 numeric IDs
        if let first = v2LightIDs.first, Int(first) != nil {
            return v2LightIDs  // Already v1 format
        }

        // Fetch all v1 lights to build a mapping
        let v1Lights = try await fetchLights()

        // Also fetch v2 lights to get the id_v1 mapping
        // v2 lights have "id_v1": "/lights/N" which maps to v1 numeric ID
        var v2ToV1: [String: String] = [:]

        // Try to match via the v2 API id_v1 field
        // Since we can't easily call v2 from here, try matching by uniqueid
        // v1 lights have "uniqueid": "00:17:88:01:XX:XX:XX:XX-0b"
        // This is a stable hardware identifier that doesn't change between v1/v2

        // Build reverse lookup: for each v1 light, store its uniqueid
        var uniqueIDToV1ID: [String: String] = [:]
        for (v1ID, light) in v1Lights {
            if let uniqueID = light["uniqueid"] as? String {
                uniqueIDToV1ID[uniqueID] = v1ID
            }
        }

        // Since v2 UUIDs are derived from the bridge, we can try a direct approach:
        // Just return all v1 light IDs that are in the same group
        // The caller will match them by position (channel 0 = first light, etc.)
        let allV1IDs = Array(v1Lights.keys).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }

        // If we have the same count, return them
        if allV1IDs.count >= v2LightIDs.count {
            return Array(allV1IDs.prefix(v2LightIDs.count))
        }

        return allV1IDs
    }

    /// Get ALL v1 light IDs for a specific v1 group.
    func lightIDsForGroup(_ groupID: String) async throws -> [String] {
        if groupID == "0" {
            // Group 0 = all lights
            let lights = try await fetchLights()
            return Array(lights.keys).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }
        let data = try await get(path: "/groups/\(groupID)")
        guard let group = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lights = group["lights"] as? [String] else {
            return []
        }
        return lights
    }

    // ──────────────────────────────────────────────
    // MARK: - Private HTTP
    // ──────────────────────────────────────────────

    private func get(path: String) async throws -> Data {
        let urlStr = "\(baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            throw HueAPIError.badURL(urlStr)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        log.info("V1 GET \(urlStr, privacy: .public)")
        return try await execute(req)
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let urlStr = "\(baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            throw HueAPIError.badURL(urlStr)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        log.info("V1 POST \(urlStr, privacy: .public)")
        return try await execute(req)
    }

    private func put(path: String, body: [String: Any]) async throws -> Data {
        let urlStr = "\(baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            throw HueAPIError.badURL(urlStr)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        log.info("V1 PUT \(urlStr, privacy: .public)")
        return try await execute(req)
    }

    private func delete(path: String) async throws -> Data {
        let urlStr = "\(baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            throw HueAPIError.badURL(urlStr)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        log.info("V1 DELETE \(urlStr, privacy: .public)")
        return try await execute(req)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        log.info("V1 HTTP \(http.statusCode, privacy: .public) ← \(request.url?.path ?? "", privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                log.error("V1 Error: \(errorBody, privacy: .public)")
            }
            throw HueAPIError.httpError(http.statusCode)
        }
        return data
    }

    // ──────────────────────────────────────────────
    // MARK: - Response Parsing
    // ──────────────────────────────────────────────

    /// v1 POST responses return: [{"success":{"id":"42"}}]
    /// Extract the created resource ID.
    private func extractCreatedID(from data: Data) throws -> String {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let success = first["success"] as? [String: Any],
              let id = success["id"] as? String else {
            // Some endpoints return the ID directly in the value
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = array.first,
               let success = first["success"] as? [String: Any] {
                // Try to get the first value (v1 returns different key names)
                if let firstValue = success.values.first as? String {
                    // Extract just the ID portion (e.g., "/scenes/abc123" → "abc123")
                    let components = firstValue.split(separator: "/")
                    return String(components.last ?? Substring(firstValue))
                }
            }
            let raw = String(data: data, encoding: .utf8) ?? "?"
            throw HueAPIError.decodingFailed("Cannot extract v1 resource ID from: \(raw)")
        }
        return id
    }

    /// Count top-level keys in a v1 dict response (used for capacity check).
    private func countTopLevelKeys(in data: Data) -> Int {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return dict.count
    }
}
