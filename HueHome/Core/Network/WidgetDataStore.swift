// WidgetDataStore.swift
// CastChroma — Epic 5 / Widget
//
// Shared data layer between the main app and the widget extension.
// Uses App Group UserDefaults (group.com.lightshade.app) so both processes
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
}

// MARK: - WidgetDataStore

final class WidgetDataStore {
    static let shared = WidgetDataStore()
    private init() {}

    private let group = "group.com.lightshade.app"
    private var ud: UserDefaults? { UserDefaults(suiteName: group) }

    private enum Key {
        static let rooms     = "hue_widget_rooms_v1"
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

    // ──────────────────────────────────────────────
    // MARK: - Read (called from widget)
    // ──────────────────────────────────────────────

    var rooms: [WidgetRoomSnapshot] {
        guard let d = ud?.data(forKey: Key.rooms),
              let r = try? JSONDecoder().decode([WidgetRoomSnapshot].self, from: d)
        else { return [] }
        return r
    }

    var bridgeIP:    String? { ud?.string(forKey: Key.bridgeIP) }
    var token:       String? { ud?.string(forKey: Key.token) }
    var lastUpdated: Date?   { ud?.object(forKey: Key.updatedAt) as? Date }
    var isPaired:    Bool    { !(bridgeIP?.isEmpty ?? true) }

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
/// Handles the Hue Bridge self-signed TLS certificate.
enum WidgetAPIClient {

    // Shared URLSession with cert-trust delegate
    private static let session: URLSession = {
        URLSession(configuration: .default,
                   delegate: TrustDelegate(),
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

    // ──────────────────────────────────────────────
    // MARK: - TLS Trust (Hue self-signed cert)
    // ──────────────────────────────────────────────

    private class TrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                      URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod ==
                    NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
