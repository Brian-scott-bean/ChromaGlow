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

// MARK: - Bridge-stored resource requirement (Composer 2 packet 5)

/// Exactly what one bridge-stored animation costs, derived from the arithmetic
/// `BridgeAnimationEngine.upload` actually executes.
///
/// Rule CONDITIONS and rule ACTIONS are counted in aggregate, bridge-wide —
/// they are resources the bridge allocates across every rule, not per-rule
/// maxima. (The separate per-rule ceiling of 8 actions is a *shape* check on
/// one rule, validated before every POST in the uploader; it is not a
/// substitute for having enough total actions available, and neither replaces
/// the other.)
///
/// All integer arithmetic: no `Double` rounding anywhere in capacity maths.
struct BridgeStoredRequirement: Equatable {
    /// Every light in the room — no longer clamped (packet 5).
    let lights: Int
    let steps: Int

    /// Integer ceiling division. `ceilDiv(l, 7) == (l + 6) / 7`.
    static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        guard b > 0 else { return 0 }
        return (a + b - 1) / b
    }

    /// One rule per ≤7-light chunk, per step.
    var ruleResources: Int { steps * Self.ceilDiv(lights, 7) }

    /// Every rule carries the same two conditions (status `eq`, `lastupdated dx`).
    var ruleConditions: Int { ruleResources * 2 }

    /// Every light contributes one action in every step, plus one
    /// sensor-advance action on the final chunk of every NON-final step — the
    /// last step advances nothing and waits for the schedule.
    var ruleActions: Int { (steps * lights) + max(0, steps - 1) }

    var sensors: Int { 1 }
    var schedules: Int { 1 }
    /// The rules-chain uploader drives light states directly (audit L-04).
    var scenes: Int { 0 }

    /// Which reported resource fell short. Drives honest copy: only a
    /// rules-ONLY shortage may claim the bridge is out of *rule slots*.
    enum Shortage: String, CaseIterable, Equatable, Sendable {
        case rules, ruleConditions, ruleActions, sensors, schedules
    }
}

// MARK: - Bridge-reported capacity

/// What the bridge itself says is free, decoded from `GET /api/<key>/capabilities`.
///
/// Every field is optional and every absence means UNKNOWN — never zero, never
/// a default. Packet 5 deleted the previous `BridgeResourceCapacity`, whose
/// totals (`250`/`250`/`100`/`200`) were hard-coded guesses: it fetched
/// `/config` purely as a reachability probe, threw the body away, then counted
/// existing resources with four more GETs and subtracted from constants. A
/// preflight built on assumed totals cannot honestly be called a measurement,
/// so nothing here claims a number the bridge did not report.
///
/// Only `available` is modelled. `total` is not required — the preflight never
/// needs it — and inventing a field the verified response may not carry would
/// reintroduce exactly the kind of assumption this replaces.
struct BridgeReportedCapacity: Equatable, Sendable {
    let rulesAvailable: Int?
    /// Nested under `rules` in the v1 capabilities response, when present.
    let ruleConditionsAvailable: Int?
    let ruleActionsAvailable: Int?
    let sensorsAvailable: Int?
    let schedulesAvailable: Int?

    static let unknown = BridgeReportedCapacity(
        rulesAvailable: nil, ruleConditionsAvailable: nil,
        ruleActionsAvailable: nil, sensorsAvailable: nil, schedulesAvailable: nil)
}

/// The preflight verdict.
///
/// **This is a point-in-time check, not a reservation.** The capabilities read
/// is a snapshot; another controller, a bridge routine, or a second app can
/// consume slots between the read and the last `createRule`, and the v1 API
/// offers no way to hold capacity. So: it prevents uploads already known not
/// to fit, unknown capacity fails closed, and a creation failure AFTER a
/// passing preflight is never re-labelled a capacity problem.
enum BridgeCapacityVerdict: Equatable, Sendable {
    case fits
    case insufficient(
        required: BridgeStoredRequirement,
        reported: BridgeReportedCapacity,
        shortages: [BridgeStoredRequirement.Shortage])
    /// Fetch failed, or a required field was absent/undecodable.
    case unknown(reason: String)
}

extension BridgeReportedCapacity {

    /// Compare against a requirement, using ONLY values the bridge reported.
    /// A missing required field is `unknown`, never an optimistic pass.
    func verdict(for need: BridgeStoredRequirement) -> BridgeCapacityVerdict {
        var missing: [String] = []
        func value(_ v: Int?, _ name: String) -> Int? {
            if v == nil { missing.append(name) }
            return v
        }
        let rules = value(rulesAvailable, "rules.available")
        let conditions = value(ruleConditionsAvailable, "rules.conditions.available")
        let actions = value(ruleActionsAvailable, "rules.actions.available")
        let sensors = value(sensorsAvailable, "sensors.available")
        let schedules = value(schedulesAvailable, "schedules.available")

        guard let rules, let conditions, let actions, let sensors, let schedules else {
            return .unknown(reason: "bridge did not report " + missing.joined(separator: ", "))
        }

        var shortages: [BridgeStoredRequirement.Shortage] = []
        if rules < need.ruleResources { shortages.append(.rules) }
        if conditions < need.ruleConditions { shortages.append(.ruleConditions) }
        if actions < need.ruleActions { shortages.append(.ruleActions) }
        if sensors < need.sensors { shortages.append(.sensors) }
        if schedules < need.schedules { shortages.append(.schedules) }

        // Scene capacity deliberately does not gate: the uploader creates zero
        // scenes, so requiring free scene slots produced false "bridge full"
        // refusals on scene-heavy bridges (audit L-04). Resourcelinks do not
        // gate either — the uploader already treats that failure as non-fatal.
        return shortages.isEmpty
            ? .fits
            : .insufficient(required: need, reported: self, shortages: shortages)
    }

    /// Every required figure, for diagnostics. The user-facing sentence names
    /// at most one resource; the log always carries all five, so the real
    /// shortage is recoverable without ever being guessed at in the UI.
    func diagnosticSummary(for need: BridgeStoredRequirement) -> String {
        func pair(_ label: String, _ required: Int, _ available: Int?) -> String {
            "\(label) need \(required)/have \(available.map(String.init) ?? "?")"
        }
        return [
            pair("rules", need.ruleResources, rulesAvailable),
            pair("conditions", need.ruleConditions, ruleConditionsAvailable),
            pair("actions", need.ruleActions, ruleActionsAvailable),
            pair("sensors", need.sensors, sensorsAvailable),
            pair("schedules", need.schedules, schedulesAvailable),
        ].joined(separator: ", ")
    }
}

// MARK: - Errors

enum HueV1ClientError: LocalizedError {
    /// A v2 light ID could not be mapped to a v1 numeric ID via `id_v1` (M-04).
    case unresolvedLightID(String)

    /// The v1 API answered HTTP 200 with an error envelope
    /// (`[{"error":{"type":…,"address":…,"description":…}}]`) — packet 5.
    ///
    /// v1 signals most resource failures this way, so `execute`'s non-2xx check
    /// never fired and the body fell through to `extractCreatedID`, surfacing a
    /// genuine API error as `decodingFailed("Cannot extract v1 resource ID
    /// from: …")`. Fields are optional because the envelope is only as
    /// complete as the bridge made it.
    ///
    /// Deliberately NOT classified here. Callers must not infer capacity
    /// exhaustion from `description` text: it is brittle, potentially
    /// localized, and no captured hardware response justifies a specific
    /// discriminator yet. The measured preflight is the only place the app
    /// knows a bridge is full.
    case apiError(type: Int?, address: String?, description: String?)

    var errorDescription: String? {
        switch self {
        case .unresolvedLightID(let id):
            return "HueV1Client: no id_v1 mapping for v2 light \(id) — cannot target v1 API safely."
        case .apiError(let type, let address, let description):
            let parts = [
                type.map { "type \($0)" },
                address.map { "at \($0)" },
                description,
            ].compactMap { $0 }
            return "Hue bridge rejected the request (" + parts.joined(separator: ", ") + ")"
        }
    }
}

// MARK: - HueV1Client

class HueV1Client: @unchecked Sendable {

    private let ip: String
    let token: String  // Internal: used by BridgeAnimationEngine for rule action paths
    private let log = Logger(subsystem: "com.chromaglow.app", category: "V1API")

    /// Expose bridge IP for manifest storage.
    var bridgeIP: String { ip }

    // Shared pinned bridge trust (H-01/D-016) — same delegate as HueAPIClient.
    // Eager, not lazy: this class is @unchecked Sendable, and a lazy var's
    // first touch from two threads is a data race (audit L-03).
    private let session: URLSession =
        URLSession(configuration: .default, delegate: BridgePinnedTrustDelegate.shared, delegateQueue: nil)

    init(ip: String, token: String) {
        self.ip = ip
        self.token = token
    }

    // ──────────────────────────────────────────────
    // MARK: - Base URL
    // ──────────────────────────────────────────────

    private var baseURL: String { "https://\(ip)/api/\(token)" }

    // ──────────────────────────────────────────────
    // MARK: - Log Redaction (audit H-03)
    // ──────────────────────────────────────────────
    // The v1 API carries the application key in the URL path (/api/{token}/…),
    // so nothing derived from baseURL/request.url may reach a log sink.

    /// Strips the `/api/{token}` prefix from a v1 URL path, leaving only the
    /// token-free resource path (e.g. "/api/SECRET/schedules/3" → "/schedules/3").
    /// A whitelist element segment is ANOTHER app's key (H-03) — masked in
    /// the same pass so `/config/whitelist/<key>` can never reach a log sink.
    static func redactedPath(fromV1URLPath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.first == "api" else { return maskWhitelistElement(in: path) }
        return maskWhitelistElement(in: "/" + components.dropFirst(2).joined(separator: "/"))
    }

    /// Masks the path segment FOLLOWING "whitelist" — that segment is an
    /// application key belonging to some app on this bridge.
    static func maskWhitelistElement(in path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return path }
        for index in 0..<(parts.count - 1) where parts[index] == "whitelist" {
            parts[index + 1] = "<redacted>"
        }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    /// Removes this client's token (and any /api/{…} or whitelist/{…}
    /// segment) from free-form text such as bridge error bodies before it
    /// can be logged.
    func sanitizedForLog(_ text: String) -> String {
        var result = text
        if !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "<redacted>")
        }
        result = result.replacingOccurrences(
            of: #"/api/[^/\s"\\]+"#,
            with: "/api/<redacted>",
            options: .regularExpression
        )
        // Error bodies echo whitelist DELETE addresses — those embed other
        // apps' keys (H-03).
        result = result.replacingOccurrences(
            of: #"whitelist/[^/\s"\\]+"#,
            with: "whitelist/<redacted>",
            options: .regularExpression
        )
        return result
    }

    // ──────────────────────────────────────────────
    // MARK: - Whitelist (Family Sharing revocation — the shipped spike)
    // ──────────────────────────────────────────────
    // Modern Signify firmware is believed to have removed the local
    // whitelist DELETE (and possibly the read). Rather than blocking on a
    // hardware spike, BOTH outcomes are first-class here: fetchWhitelist
    // returns nil when the firmware omits the map, and deleteWhitelistEntry
    // trusts only a verify-by-re-read — never the DELETE's own response.

    struct WhitelistEntry: Identifiable, Equatable {
        /// The FULL key — needed to issue the DELETE; another app's secret
        /// (H-03): never logged, never rendered whole.
        let element: String
        /// "app#device" as the bridge stores it.
        let name: String
        let createDate: String?
        let lastUseDate: String?

        var id: String { element }
        /// The only renderable form: first 6 chars + ellipsis.
        var displayID: String { element.count > 8 ? "\(element.prefix(6))…" : "••••" }
    }

    enum WhitelistDeleteOutcome: Equatable {
        /// The re-read no longer lists the element — genuinely gone.
        case deletedVerified
        /// The bridge refused (or the whitelist isn't exposed) — the key
        /// can only be revoked via official Hue tooling.
        case unsupportedByFirmware(String)
        /// The DELETE claimed success but the re-read still lists it —
        /// treat exactly like unsupported.
        case stillPresent
    }

    /// GET /config and extract the whitelist. nil = this firmware does not
    /// expose it locally (the expected answer on current bridges).
    func fetchWhitelist() async throws -> [WhitelistEntry]? {
        let data = try await get(path: "/config")
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HueAPIError.decodingFailed("v1 /config did not return an object")
        }
        guard let whitelist = dict["whitelist"] as? [String: [String: Any]] else {
            return nil
        }
        return whitelist.map { element, fields in
            WhitelistEntry(
                element: element,
                name: fields["name"] as? String ?? "unknown app",
                createDate: fields["create date"] as? String,
                lastUseDate: fields["last use date"] as? String
            )
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Best-effort DELETE, then verify by re-read — the re-read is the only
    /// trusted signal (ancient firmware honors the delete; modern firmware
    /// may 200 an error body, 403, or silently no-op).
    func deleteWhitelistEntry(element: String) async throws -> WhitelistDeleteOutcome {
        var bridgeError: String?
        do {
            let data = try await delete(path: "/config/whitelist/\(element)")
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let err = array.first?["error"] as? [String: Any],
               let description = err["description"] as? String {
                bridgeError = sanitizedForLog(description)
            }
        } catch HueAPIError.httpError(let status) {
            bridgeError = "HTTP \(status)"
        }
        let after = try await fetchWhitelist()
        return Self.whitelistDeleteOutcome(afterReread: after, element: element,
                                           bridgeError: bridgeError)
    }

    /// Pure outcome mapping (unit-tested): the re-read decides.
    static func whitelistDeleteOutcome(
        afterReread: [WhitelistEntry]?,
        element: String,
        bridgeError: String?
    ) -> WhitelistDeleteOutcome {
        guard let afterReread else {
            return .unsupportedByFirmware(
                bridgeError ?? "This bridge's firmware doesn't expose its key list locally."
            )
        }
        if !afterReread.contains(where: { $0.element == element }) {
            // Gone on re-read — the delete worked, whatever the DELETE said.
            return .deletedVerified
        }
        if let bridgeError { return .unsupportedByFirmware(bridgeError) }
        return .stillPresent
    }

    // ──────────────────────────────────────────────
    // MARK: - Token authorization probe (Family Sharing)
    // ──────────────────────────────────────────────

    enum TokenProbeOutcome {
        case authorized
        /// The bridge explicitly refused this key (v1 error type 1 or an
        /// HTTP 401/403) — the L-30-grade signal, never inferred from
        /// network failure.
        case unauthorized
    }

    /// Cheap liveness check for a just-received guest key BEFORE anything
    /// persists. v1 answers GET /lights with HTTP 200 either way: an
    /// unauthorized key yields [{"error":{"type":1,…}}], an authorized one
    /// a lights dictionary. Network/transport failures THROW — callers
    /// must treat those as unreachable, not as revocation.
    func probeTokenAuthorization() async throws -> TokenProbeOutcome {
        do {
            let data = try await get(path: "/lights")
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let error = array.first?["error"] as? [String: Any],
               (error["type"] as? Int) == 1 {
                return .unauthorized
            }
            return .authorized
        } catch HueAPIError.httpError(let status) where status == 401 || status == 403 {
            return .unauthorized
        }
    }

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

    /// Ask the BRIDGE what is free (packet 5).
    ///
    /// One authenticated `GET /api/<key>/capabilities` replaces the five GETs
    /// this used to make, and — more importantly — replaces four hard-coded
    /// totals. The old version fetched `/config` as a reachability probe,
    /// discarded the body, counted existing rules/sensors/schedules/scenes, and
    /// subtracted from constants. That is an assumption dressed as a
    /// measurement; on a bridge with different capacities it was wrong in both
    /// directions.
    ///
    /// Throws on transport failure; the caller turns that into `.unknown` and
    /// fails closed. A body that parses but omits a required figure is also
    /// unknown — see `decodeReportedCapacity`.
    func fetchReportedCapacity() async throws -> BridgeReportedCapacity {
        let data = try await get(path: "/capabilities")
        return Self.decodeReportedCapacity(data)
    }

    /// Decode the v1 capabilities body.
    ///
    /// Shape (per the documented v1 `/capabilities` response): each resource is
    /// an object carrying `available`, and `rules` additionally nests
    /// `conditions` and `actions` objects of the same shape.
    ///
    /// Every field is read defensively and independently. A missing or
    /// non-numeric figure stays nil, which the verdict treats as UNKNOWN and
    /// fails closed on — it is never defaulted, and it never falls back to the
    /// deleted constants. Any structural surprise therefore degrades to "we
    /// don't know", which is the honest answer and the safe one.
    ///
    /// The fixtures in `BridgeAnimationCorrectnessTests` exercise this against
    /// a documented-shape body plus four malformed variants; a synthetic body
    /// proves the PARSER, and is not evidence about a real bridge. The
    /// device checklist captures a real response so this can be tightened.
    static func decodeReportedCapacity(_ data: Data) -> BridgeReportedCapacity {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        func available(_ node: Any?) -> Int? {
            guard let dict = node as? [String: Any] else { return nil }
            return dict["available"] as? Int
        }
        let rules = root["rules"] as? [String: Any]
        return BridgeReportedCapacity(
            rulesAvailable: available(rules),
            ruleConditionsAvailable: available(rules?["conditions"]),
            ruleActionsAvailable: available(rules?["actions"]),
            sensorsAvailable: available(root["sensors"]),
            schedulesAvailable: available(root["schedules"]))
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

    /// Convert v2 UUID light IDs to v1 numeric IDs **by identity** (M-04):
    /// each v2 light object carries `id_v1: "/lights/N"`. Per-light colors are
    /// positional downstream (channel i drives output[i]), so `output[i]` MUST
    /// be the v1 id of `v2LightIDs[i]` — positional guessing over the whole
    /// bridge scrambled animations and lit bulbs outside the room.
    ///
    /// If the input IDs are already numeric (v1 format), returns them as-is.
    /// Throws when any target light cannot be resolved via `id_v1` — the
    /// caller falls back to app-driven rendering rather than animating the
    /// wrong bulbs.
    func resolveV1LightIDs(from v2LightIDs: [String], v2Lights: [HueLight]) throws -> [String] {
        // Check if these are already v1 numeric IDs
        if let first = v2LightIDs.first, Int(first) != nil {
            return v2LightIDs  // Already v1 format
        }

        let v2ByID = Dictionary(v2Lights.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        var resolved: [String] = []
        resolved.reserveCapacity(v2LightIDs.count)
        for v2ID in v2LightIDs {
            guard let idV1 = v2ByID[v2ID]?.id_v1,
                  let numeric = idV1.split(separator: "/").last.map(String.init),
                  Int(numeric) != nil else {
                throw HueV1ClientError.unresolvedLightID(v2ID)
            }
            resolved.append(numeric)
        }
        return resolved
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
        // H-03: `path` is token-free but may carry a whitelist element.
        log.info("V1 GET \(Self.maskWhitelistElement(in: path))")
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
        log.info("V1 POST \(Self.maskWhitelistElement(in: path))")
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
        log.info("V1 PUT \(Self.maskWhitelistElement(in: path))")
        return try await execute(req)
    }

    private func delete(path: String) async throws -> Data {
        let urlStr = "\(baseURL)\(path)"
        guard let url = URL(string: urlStr) else {
            throw HueAPIError.badURL(urlStr)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        // H-03: the whitelist DELETE path embeds another app's key.
        log.info("V1 DELETE \(Self.maskWhitelistElement(in: path))")
        return try await execute(req)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        // request.url embeds the token — log only the redacted resource path.
        let resourcePath = Self.redactedPath(fromV1URLPath: request.url?.path ?? "")
        log.info("V1 HTTP \(http.statusCode, privacy: .public) ← \(resourcePath)")
        guard (200...299).contains(http.statusCode) else {
            if let errorBody = String(data: data, encoding: .utf8) {
                // v1 error bodies can echo /api/{token} addresses — sanitize first.
                log.error("V1 Error [\(resourcePath)]: \(self.sanitizedForLog(errorBody))")
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
            // Packet 5: v1 answers HTTP 200 with an error ENVELOPE for most
            // resource failures, so `execute`'s status check never fires and
            // a real API error used to surface here as a decode failure.
            // Recognise it and throw a TYPED error instead — still without
            // interpreting what it means.
            if let apiError = Self.parsedAPIError(from: data) {
                log.error("V1 API error: \(self.sanitizedForLog(apiError.localizedDescription))")
                throw apiError
            }
            let raw = String(data: data, encoding: .utf8) ?? "?"
            throw HueAPIError.decodingFailed("Cannot extract v1 resource ID from: \(raw)")
        }
        return id
    }

    /// Parse `[{"error":{"type":…,"address":…,"description":…}}]`, or nil when
    /// the body is not an error envelope.
    ///
    /// Extracts, never classifies. Deciding that a given error means "the
    /// bridge is full" requires a documented or captured discriminator, and
    /// none exists yet — so callers treat every one of these as a generic
    /// upload failure. Matching on the English `description` would be brittle
    /// and possibly localized, and is deliberately not done anywhere.
    static func parsedAPIError(from data: Data) -> HueV1ClientError? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let error = array.first?["error"] as? [String: Any]
        else { return nil }
        return .apiError(
            type: error["type"] as? Int,
            address: error["address"] as? String,
            description: error["description"] as? String)
    }
}

// H-03: a default reflective dump (String(describing:)/(reflecting:))
// would print `element` — another app's key. Both textual forms are
// pinned to the truncated display id.
extension HueV1Client.WhitelistEntry: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "\(displayID) (\(name))" }
    var debugDescription: String { description }
}
