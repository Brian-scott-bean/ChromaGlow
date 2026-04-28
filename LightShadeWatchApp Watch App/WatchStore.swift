// WatchStore.swift
// LightShadeWatchApp — Observable data layer for the full watchOS app.
//
// PRIMARY sync:  WatchConnectivity (WCSession) — iPhone pushes rooms via
//                updateApplicationContext whenever WidgetDataStore.write(rooms:) fires.
//                applicationContext is delivered as soon as the watch app comes to the
//                foreground, even if the phone was not reachable at write time.
//
// SECONDARY:     watch-local UserDefaults cache so data survives watch app restarts.
//
// WRITE path:    iPhone app → WidgetDataStore.write(rooms:)
//                           → WatchSessionManager.push(rooms:ip:token:)
//                           → WCSession.updateApplicationContext
//                           → WatchStore.session(_:didReceiveApplicationContext:)
//                           → rooms published + saved to local cache

import SwiftUI
import Foundation
import Combine
import WatchConnectivity

// MARK: - Room Model

struct WatchRoom: Identifiable, Codable {
    let id:             String
    let name:           String
    let archetype:      String?
    var isOn:           Bool
    var brightness:     Double   // 1–100
    let lightCount:     Int
    let groupedLightId: String?
}

// MARK: - Preset

enum WatchPreset: String, CaseIterable {
    case energize, read, relax, sleep

    var label: String {
        switch self {
        case .energize: return "Energize"
        case .read:     return "Read"
        case .relax:    return "Relax"
        case .sleep:    return "Sleep"
        }
    }
    var icon: String {
        switch self {
        case .energize: return "bolt.fill"
        case .read:     return "book.fill"
        case .relax:    return "moon.stars.fill"
        case .sleep:    return "zzz"
        }
    }
    var color: Color {
        switch self {
        case .energize: return Color(hue: 0.58, saturation: 0.8, brightness: 1.0)
        case .read:     return Color(hue: 0.12, saturation: 0.7, brightness: 1.0)
        case .relax:    return Color(hue: 0.09, saturation: 0.8, brightness: 0.95)
        case .sleep:    return Color(hue: 0.07, saturation: 0.6, brightness: 0.7)
        }
    }
    var brightness: Double {
        switch self {
        case .energize: return 100
        case .read:     return 75
        case .relax:    return 40
        case .sleep:    return 6
        }
    }
    var mirek: Int {
        switch self {
        case .energize: return 156
        case .read:     return 280
        case .relax:    return 420
        case .sleep:    return 490
        }
    }
}

// MARK: - WatchStore

@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published var rooms:     [WatchRoom] = []
    @Published var isPaired:  Bool        = false
    @Published var isLoading: Bool        = false
    @Published var errorMsg:  String?     = nil

    // Watch-local cache keys (UserDefaults.standard on the WATCH device)
    private enum CacheKey {
        static let rooms    = "wc_rooms_v1"
        static let bridgeIP = "wc_bridge_ip"
        static let token    = "wc_token"
    }

    private var bridgeIP: String? { UserDefaults.standard.string(forKey: CacheKey.bridgeIP) }
    private var token:    String? { UserDefaults.standard.string(forKey: CacheKey.token) }

    private override init() {
        super.init()
        loadFromLocalCache()
        activateWCSession()
    }

    // MARK: - WatchConnectivity

    private func activateWCSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Local Cache

    func loadFromLocalCache() {
        guard let data    = UserDefaults.standard.data(forKey: CacheKey.rooms),
              let decoded = try? JSONDecoder().decode([WatchRoom].self, from: data)
        else { return }
        rooms    = decoded
        isPaired = !(bridgeIP?.isEmpty ?? true)
    }

    private func saveToLocalCache() {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        UserDefaults.standard.set(data, forKey: CacheKey.rooms)
    }

    // MARK: - Toggle Room

    func toggleRoom(_ room: WatchRoom) async {
        guard let glID = room.groupedLightId,
              let ip   = bridgeIP,
              let tok  = token else { return }
        let newState = !room.isOn
        if let idx = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[idx].isOn = newState
        }
        await patch(id: glID, body: ["on": ["on": newState]], ip: ip, token: tok)
        saveToLocalCache()
    }

    // MARK: - Set Brightness

    func setBrightness(_ brightness: Double, for room: WatchRoom) async {
        guard let glID = room.groupedLightId,
              let ip   = bridgeIP,
              let tok  = token else { return }
        if let idx = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[idx].brightness = brightness
            rooms[idx].isOn       = brightness > 0
        }
        let body: [String: Any] = [
            "on":      ["on": brightness > 0],
            "dimming": ["brightness": brightness]
        ]
        await patch(id: glID, body: body, ip: ip, token: tok)
        saveToLocalCache()
    }

    // MARK: - Apply Preset (all rooms)

    func applyPreset(_ preset: WatchPreset) async {
        guard let ip  = bridgeIP,
              let tok = token else { return }
        let body: [String: Any] = [
            "on":                ["on": true],
            "dimming":           ["brightness": preset.brightness],
            "color_temperature": ["mirek": preset.mirek],
            "dynamics":          ["duration": 800]
        ]
        for i in rooms.indices {
            rooms[i].isOn       = true
            rooms[i].brightness = preset.brightness
        }
        await withTaskGroup(of: Void.self) { group in
            for room in rooms {
                guard let glID = room.groupedLightId else { continue }
                let gid = glID
                group.addTask { await self.patch(id: gid, body: body, ip: ip, token: tok) }
            }
        }
        saveToLocalCache()
    }

    // MARK: - All Off

    func allOff() async {
        guard let ip  = bridgeIP,
              let tok = token else { return }
        for i in rooms.indices { rooms[i].isOn = false }
        let body: [String: Any] = ["on": ["on": false]]
        await withTaskGroup(of: Void.self) { group in
            for room in rooms {
                guard let glID = room.groupedLightId else { continue }
                let gid = glID
                group.addTask { await self.patch(id: gid, body: body, ip: ip, token: tok) }
            }
        }
        saveToLocalCache()
    }

    // MARK: - Network

    private func patch(id: String, body: [String: Any], ip: String, token: String) async {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light/\(id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token,              forHTTPHeaderField: "hue-application-key")
        req.httpBody  = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession(configuration: .default,
                                  delegate: TrustAll(),
                                  delegateQueue: nil).data(for: req)
    }

    private final class TrustAll: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ s: URLSession,
                        didReceive c: URLAuthenticationChallenge,
                        completionHandler h: @escaping (URLSession.AuthChallengeDisposition,
                                                        URLCredential?) -> Void) {
            if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) }
            else { h(.performDefaultHandling, nil) }
        }
    }
}

// MARK: - WCSessionDelegate (watch side)

extension WatchStore: WCSessionDelegate {

    /// Called when the iPhone pushes a new applicationContext.
    /// Fires immediately if the watch app is active; delivered on next
    /// launch if the watch app was not running at send time.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let roomsData = applicationContext["wc_rooms_v1"] as? Data,
              let decoded   = try? JSONDecoder().decode([WatchRoom].self, from: roomsData)
        else { return }

        let ip    = applicationContext["wc_bridge_ip"] as? String ?? ""
        let token = applicationContext["wc_token"]     as? String ?? ""

        // Persist to watch-local cache
        UserDefaults.standard.set(roomsData, forKey: CacheKey.rooms)
        if !ip.isEmpty    { UserDefaults.standard.set(ip,    forKey: CacheKey.bridgeIP) }
        if !token.isEmpty { UserDefaults.standard.set(token, forKey: CacheKey.token) }

        // Update published properties on MainActor
        Task { @MainActor in
            self.rooms    = decoded
            self.isPaired = !ip.isEmpty
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { print("WatchStore WCSession: activation error — \(error)") }
        // Replay any context delivered while the app was not running
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty {
            self.session(session, didReceiveApplicationContext: ctx)
        }
    }
}

// MARK: - Archetype Icon

func watchRoomIcon(_ archetype: String?) -> String {
    switch archetype?.lowercased() {
    case "living_room":             return "sofa.fill"
    case "kitchen":                 return "fork.knife"
    case "bedroom", "kids_bedroom": return "bed.double.fill"
    case "bathroom":                return "shower.fill"
    case "office", "computer":      return "desktopcomputer"
    case "gym":                     return "dumbbell.fill"
    case "hallway":                 return "door.left.hand.open"
    case "garage":                  return "car.fill"
    case "terrace", "garden":       return "leaf.fill"
    case "tv":                      return "tv.fill"
    case "studio", "music":         return "music.note"
    default:                        return "lightbulb.fill"
    }
}
