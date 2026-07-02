// WidgetDataStore.swift
// CastChroma — Epic 5 / Widget
//
// Shared data layer between the main app and the widget extension.
// Uses App Group UserDefaults (group.com.huehome.pro) so both processes
// can read and write without XPC or file-coordination overhead.
//
// WRITE path: DashboardViewModel → after every loadAll() success.
// READ path:  HueWidgetProvider.getTimeline() → build timeline entry.
//
// Also contains the lightweight WidgetAPIClient used by the widget
// to fetch a fresh grouped_light state in a single network call.

import Foundation

// MARK: - Shared Room Model

struct WidgetRoomSnapshot: Codable, Identifiable {
    let id:             String
    let name:           String
    let archetype:      String?
    var isOn:           Bool
    var brightness:     Double   // 1–100
    let lightCount:     Int
    let groupedLightId: String?  // enables fresh fetch without re-fetching rooms
    let bridgeID:       String?  // bridge routing key for multi-bridge intent writes

    init(
        id: String,
        name: String,
        archetype: String?,
        isOn: Bool,
        brightness: Double,
        lightCount: Int,
        groupedLightId: String?,
        bridgeID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.isOn = isOn
        self.brightness = brightness
        self.lightCount = lightCount
        self.groupedLightId = groupedLightId
        self.bridgeID = bridgeID
    }
}

struct WidgetBridgeCredentials: Codable {
    let bridgeID: String
    let ip: String
    let token: String
}

// MARK: - WidgetDataStore

final class WidgetDataStore: @unchecked Sendable {
    static let shared = WidgetDataStore()
    private init() {}

    private let group = "group.com.huehome.pro"
    private var ud: UserDefaults? { UserDefaults(suiteName: group) }

    private enum Key {
        static let rooms     = "hue_widget_rooms_v1"
        static let bridges   = "hue_widget_bridges_v1"
        static let bridgeIP  = "hue_widget_bridge_ip"
        static let token     = "hue_widget_token"
        static let updatedAt = "hue_widget_updated_at"
    }

    // ──────────────────────────────────────────────
    // MARK: - Write (called from main app)
    // ──────────────────────────────────────────────

    func write(rooms: [WidgetRoomSnapshot]) {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        ud?.set(data, forKey: Key.rooms)
        ud?.set(Date(), forKey: Key.updatedAt)
    }

    func write(ip: String, token: String) {
        ud?.set(ip,    forKey: Key.bridgeIP)
        ud?.set(token, forKey: Key.token)
    }

    func write(bridges: [String: WidgetBridgeCredentials]) {
        guard let data = try? JSONEncoder().encode(bridges) else { return }
        ud?.set(data, forKey: Key.bridges)
        if let first = bridges.values.first {
            // Legacy fallback keys used by older widget/watch code paths.
            ud?.set(first.ip,    forKey: Key.bridgeIP)
            ud?.set(first.token, forKey: Key.token)
        } else {
            ud?.removeObject(forKey: Key.bridgeIP)
            ud?.removeObject(forKey: Key.token)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Read (called from widget)
    // ──────────────────────────────────────────────

    var rooms: [WidgetRoomSnapshot] {
        guard let d = ud?.data(forKey: Key.rooms),
              let r = try? JSONDecoder().decode([WidgetRoomSnapshot].self, from: d)
        else { return [] }
        return r
    }

    var bridges: [String: WidgetBridgeCredentials] {
        guard let data = ud?.data(forKey: Key.bridges),
              let decoded = try? JSONDecoder().decode([String: WidgetBridgeCredentials].self, from: data)
        else { return [:] }
        return decoded
    }

    var bridgeIP:    String? { ud?.string(forKey: Key.bridgeIP) }
    var token:       String? { ud?.string(forKey: Key.token) }
    var lastUpdated: Date?   { ud?.object(forKey: Key.updatedAt) as? Date }
    var isPaired:    Bool    { !bridges.isEmpty || !(bridgeIP?.isEmpty ?? true) }

    func credentials(for bridgeID: String?) -> WidgetBridgeCredentials? {
        if let bridgeID, let creds = bridges[bridgeID] { return creds }
        if let ip = bridgeIP, let token = token {
            return WidgetBridgeCredentials(bridgeID: bridgeID ?? "legacy-default", ip: ip, token: token)
        }
        return nil
    }

    // ──────────────────────────────────────────────
    // MARK: - TTL
    // ──────────────────────────────────────────────

    /// Seconds since the last successful write. `.infinity` if never written.
    var staleness: TimeInterval {
        guard let last = lastUpdated else { return .infinity }
        return Date().timeIntervalSince(last)
    }

    /// Returns true if the stored snapshot is older than `interval` seconds.
    /// The widget extension calls this to decide whether to show a "stale" badge.
    func isStale(olderThan interval: TimeInterval = 300) -> Bool {
        staleness > interval
    }
}

// MARK: - WidgetAPIClient

/// Lightweight, widget-only HTTP client.
/// Makes a single call to /grouped_light to refresh all room states.
/// Uses the shared pinned bridge trust delegate (M-01/D-016).
enum WidgetAPIClient {

    private static let session: URLSession = {
        URLSession(configuration: .default,
                   delegate: BridgePinnedTrustDelegate.shared,
                   delegateQueue: nil)
    }()

    // ──────────────────────────────────────────────
    // MARK: - Response Models
    // ──────────────────────────────────────────────

    struct V2Response<T: Decodable>: Decodable { let data: [T] }

    struct GLData: Decodable {
        let id:      String
        let on:      OnState
        let dimming: Dimming?
        struct OnState:  Decodable { let on: Bool }
        struct Dimming:  Decodable { let brightness: Double }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch
    // ──────────────────────────────────────────────

    /// ONE call: fetch all grouped_light states.
    /// Widget merges this against cached WidgetRoomSnapshot array.
    static func fetchGroupedLights(ip: String, token: String) async throws -> [GLData] {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(V2Response<GLData>.self, from: data).data
    }

    // The former per-target trust-all TrustDelegate (audit M-01) was replaced
    // by the shared BridgePinnedTrustDelegate (D-016).
}
