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
import WidgetKit

// MARK: - Room Model

struct WatchRoom: Identifiable, Codable {
    let id:             String
    let name:           String
    let archetype:      String?
    var isOn:           Bool
    var brightness:     Double   // 1–100
    let lightCount:     Int
    let groupedLightId: String?
    let bridgeID:       String?
}

struct WatchBridgeCredentials: Codable {
    let bridgeID: String
    let ip: String
    let token: String
}

// MARK: - Scene Model

struct WatchScene: Identifiable, Codable {
    let id:           String  // real Hue scene UUID (recall target)
    let name:         String
    let ownerGroupID: String  // matches WatchRoom.id of the owning room/zone
    let bridgeID:     String
}

// MARK: - Preset

/// Behavior (label/icon/brightness/mirek) reads from the shared LightingPreset
/// catalog (compiled into this target); the chip colors are watch styling,
/// tuned brighter for the small screen.
enum WatchPreset: String, CaseIterable {
    case energize, read, relax, sleep

    private var shared: LightingPreset {
        // The catalog is the source of truth; the cases mirror its stable ids.
        LightingPreset.find(rawValue) ?? .relax
    }

    var label: String { shared.name }
    var icon: String { shared.icon }
    var brightness: Double { shared.brightness }
    var mirek: Int { shared.mirek }

    var color: Color {
        switch self {
        case .energize: return Color(hue: 0.58, saturation: 0.8, brightness: 1.0)
        case .read:     return Color(hue: 0.12, saturation: 0.7, brightness: 1.0)
        case .relax:    return Color(hue: 0.09, saturation: 0.8, brightness: 0.95)
        case .sleep:    return Color(hue: 0.07, saturation: 0.6, brightness: 0.7)
        }
    }
}

// MARK: - WatchStore

@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published var rooms:     [WatchRoom] = []
    @Published var zones:     [WatchRoom] = []
    @Published var scenes:    [WatchScene] = []
    @Published var isPaired:  Bool        = false
    @Published var isLoading: Bool        = false
    @Published var errorMsg:  String?     = nil
    /// Last confirmed data contact (phone push, bridge refresh, or an
    /// acknowledged command). Drives the honest "Updated Xm ago" line —
    /// the timestamp was always written, never read (audit N13).
    @Published var lastSyncedAt: Date?    = nil

    /// Rooms followed by zones — the full set of controllable groups.
    var allGroups: [WatchRoom] { rooms + zones }

    /// Scenes belonging to a given room/zone.
    func scenes(forGroup groupID: String) -> [WatchScene] {
        scenes.filter { $0.ownerGroupID == groupID }
    }

    // Watch-local cache keys. Rooms/zones/ip are non-secret and stay in
    // UserDefaults.standard; the token and credential map live in the watch
    // Keychain (M-02/L-30, D-018) under the same key names as accounts.
    // nonisolated: plain String constants — the watch target's MainActor
    // default isolation otherwise blocks the nonisolated WCSession-delegate
    // and clearAllStoredData call sites.
    nonisolated private enum CacheKey {
        static let rooms    = "wc_rooms_v1"
        static let bridges  = "wc_bridges_v1"   // Keychain account (was a UserDefaults key pre-D-018)
        static let bridgeIP = "wc_bridge_ip"
        static let token    = "wc_token"        // Keychain account (was a UserDefaults key pre-D-018)
    }

    // App Group shared with complication extension (watch-side container).
    // Carries only non-secret display data (rooms, timestamps, bridge ip).
    private var watchGroup: UserDefaults? { UserDefaults(suiteName: "group.com.huehome.pro") }

    private var bridgeIP: String? { UserDefaults.standard.string(forKey: CacheKey.bridgeIP) }
    private var token:    String? { SharedKeychainStore.loadString(account: CacheKey.token) }
    private var bridges: [String: WatchBridgeCredentials] {
        guard let data = SharedKeychainStore.load(account: CacheKey.bridges),
              let decoded = try? JSONDecoder().decode([String: WatchBridgeCredentials].self, from: data)
        else { return [:] }
        return decoded
    }

    private override init() {
        super.init()
        Self.migrateLegacyPlaintextCredentials()
        loadFromLocalCache()
        activateWCSession()
    }

    /// One-time D-018 upgrade: move the pre-P1 plaintext token/credential map
    /// out of UserDefaults into the watch Keychain and scrub every plaintext
    /// copy (standard defaults + App Group mirror).
    ///
    /// Copy-first/delete-only-on-success (D-018 convention): the watch can be
    /// launched in the background before first unlock, where adding an
    /// AfterFirstUnlock item fails — deleting the source then would destroy
    /// the only credential copy. A failed save retries on the next init.
    private static func migrateLegacyPlaintextCredentials() {
        let ud = UserDefaults.standard
        if let bridgesData = ud.data(forKey: CacheKey.bridges),
           SharedKeychainStore.save(bridgesData, account: CacheKey.bridges) {
            ud.removeObject(forKey: CacheKey.bridges)
        }
        if let legacyToken = ud.string(forKey: CacheKey.token), !legacyToken.isEmpty {
            if SharedKeychainStore.save(legacyToken, account: CacheKey.token) {
                ud.removeObject(forKey: CacheKey.token)
            }
        } else {
            ud.removeObject(forKey: CacheKey.token)
        }
        let group = UserDefaults(suiteName: "group.com.huehome.pro")
        group?.removeObject(forKey: "hue_widget_token")
        group?.removeObject(forKey: "hue_widget_bridges_v1")
    }

    // MARK: - WatchConnectivity

    private func activateWCSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Local Cache

    func loadFromLocalCache() {
        if let data    = UserDefaults.standard.data(forKey: CacheKey.rooms),
           let decoded = try? JSONDecoder().decode([WatchRoom].self, from: data) {
            rooms = decoded
        }
        if let data    = UserDefaults.standard.data(forKey: "wc_zones_v1"),
           let decoded = try? JSONDecoder().decode([WatchRoom].self, from: data) {
            zones = decoded
        }
        if let data    = UserDefaults.standard.data(forKey: "wc_scenes_v1"),
           let decoded = try? JSONDecoder().decode([WatchScene].self, from: data) {
            scenes = decoded
        }
        isPaired = !bridges.isEmpty || !(bridgeIP?.isEmpty ?? true)
        lastSyncedAt = watchGroup?.object(forKey: "hue_widget_updated_at") as? Date
    }

    private func saveToLocalCache() {
        let encoder = JSONEncoder()
        let roomsData  = try? encoder.encode(rooms)
        let zonesData  = try? encoder.encode(zones)
        let scenesData = try? encoder.encode(scenes)
        if let roomsData  { UserDefaults.standard.set(roomsData,  forKey: CacheKey.rooms) }
        if let zonesData  { UserDefaults.standard.set(zonesData,  forKey: "wc_zones_v1") }
        if let scenesData { UserDefaults.standard.set(scenesData, forKey: "wc_scenes_v1") }
        // Mirror into App Group so watch complications can read rooms, zones, and
        // scenes. Display data only — credentials never enter the App Group (D-018).
        if let roomsData  { watchGroup?.set(roomsData,  forKey: "hue_widget_rooms_v1") }
        if let zonesData  { watchGroup?.set(zonesData,  forKey: "hue_widget_zones_v1") }
        if let scenesData { watchGroup?.set(scenesData, forKey: "hue_widget_scenes_v1") }
        watchGroup?.set(Date(), forKey: "hue_widget_updated_at")
        lastSyncedAt = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func credentials(for bridgeID: String?) -> WatchBridgeCredentials? {
        if let bridgeID {
            if let creds = bridges[bridgeID] { return creds }
            // A bridge-targeted command must never fall back to ANOTHER
            // bridge's credentials — a partial sync used to send room B's
            // PUT to bridge A (404, swallowed, optimistic UI showed
            // success). The legacy ip/token fallback is only for pre-
            // multibridge snapshots, whose map is empty.
            if !bridges.isEmpty { return nil }
        }
        if let ip = bridgeIP, let token = token {
            return WatchBridgeCredentials(bridgeID: bridgeID ?? "legacy-default", ip: ip, token: token)
        }
        return nil
    }

    // MARK: - Toggle Room

    func toggleRoom(_ room: WatchRoom) async {
        guard let glID = room.groupedLightId,
              let creds = credentials(for: room.bridgeID) else { return }
        let newState = !room.isOn
        // Update whichever list owns this group (room OR zone).
        if let idx = rooms.firstIndex(where: { $0.id == room.id }) { rooms[idx].isOn = newState }
        if let idx = zones.firstIndex(where: { $0.id == room.id }) { zones[idx].isOn = newState }
        let ok = await patch(id: glID, body: ["on": ["on": newState]], ip: creds.ip, token: creds.token)
        if ok {
            saveToLocalCache()
        } else {
            // Away from home / dead bridge: revert instead of persisting an
            // invented state to the cache AND complications indefinitely.
            if let idx = rooms.firstIndex(where: { $0.id == room.id }) { rooms[idx].isOn = !newState }
            if let idx = zones.firstIndex(where: { $0.id == room.id }) { zones[idx].isOn = !newState }
        }
    }

    // MARK: - Set Brightness (latest-wins mailbox)

    /// Newest requested brightness per grouped_light, waiting to be written.
    private var pendingBrightness: [String: (value: Double, ip: String, token: String)] = [:]
    /// At most one in-flight writer per grouped_light. It always picks up the
    /// newest pending value, so intermediate steps are dropped rather than queued.
    private var brightnessWriters: [String: Task<Void, Never>] = [:]

    /// Minimum spacing between two brightness PUTs for the same group. The Hue
    /// bridge is rate-limited and both the Digital Crown and a held ⊖/⊕ press
    /// emit a value per step — without coalescing, one sweep is ~99 PUTs.
    private static let brightnessWriteInterval: Duration = .milliseconds(250)

    /// Records the new brightness locally (instant UI) and hands the value to the
    /// coalescing writer. Deliberately synchronous: callers must not await a PUT.
    func setBrightness(_ brightness: Double, for room: WatchRoom) {
        guard let glID  = room.groupedLightId,
              let creds = credentials(for: room.bridgeID) else { return }
        let clamped = min(100, max(1, brightness.rounded()))

        applyLocalBrightness(clamped, groupID: room.id)
        pendingBrightness[glID] = (clamped, creds.ip, creds.token)
        startBrightnessWriter(for: glID)
    }

    /// Optimistic @Published update only — no persistence, no timeline reload.
    /// Those are expensive and happen once, when the writer drains.
    private func applyLocalBrightness(_ brightness: Double, groupID: String) {
        if let idx = rooms.firstIndex(where: { $0.id == groupID }) {
            rooms[idx].brightness = brightness; rooms[idx].isOn = brightness > 0
        }
        if let idx = zones.firstIndex(where: { $0.id == groupID }) {
            zones[idx].brightness = brightness; zones[idx].isOn = brightness > 0
        }
    }

    private func startBrightnessWriter(for glID: String) {
        // A live writer will observe the value we just stashed; don't spawn a second.
        guard brightnessWriters[glID] == nil else { return }

        brightnessWriters[glID] = Task { [weak self] in
            // `while let` drains the mailbox: each pass takes the NEWEST value and
            // discards everything that arrived while the previous PUT was in flight.
            while let next = self?.pendingBrightness.removeValue(forKey: glID) {
                await self?.patch(
                    id: glID,
                    body: ["on":      ["on": next.value > 0],
                           "dimming": ["brightness": next.value]],
                    ip: next.ip, token: next.token
                )
                try? await Task.sleep(for: Self.brightnessWriteInterval)
            }
            // No await between the drained check and this clear, and both run on
            // the MainActor — so a value cannot slip in and be stranded here.
            self?.brightnessWriters[glID] = nil
            self?.saveToLocalCache()
        }
    }

    // MARK: - Apply Preset (all rooms, or one room)

    /// Whole-home apply — the home screen's chips.
    func applyPreset(_ preset: WatchPreset) async {
        for i in rooms.indices { rooms[i].isOn = true; rooms[i].brightness = preset.brightness }
        for i in zones.indices { zones[i].isOn = true; zones[i].brightness = preset.brightness }
        await sendPreset(preset, to: allGroups)
    }

    /// Room-scoped apply — the chips INSIDE a room detail. Pressing Energize
    /// while looking at the Kitchen lights the Kitchen, not the whole house.
    func applyPreset(_ preset: WatchPreset, to group: WatchRoom) async {
        if let idx = rooms.firstIndex(where: { $0.id == group.id }) {
            rooms[idx].isOn = true; rooms[idx].brightness = preset.brightness
        }
        if let idx = zones.firstIndex(where: { $0.id == group.id }) {
            zones[idx].isOn = true; zones[idx].brightness = preset.brightness
        }
        await sendPreset(preset, to: [group])
    }

    private func sendPreset(_ preset: WatchPreset, to targets: [WatchRoom]) async {
        let body: [String: Any] = [
            "on":                ["on": true],
            "dimming":           ["brightness": preset.brightness],
            "color_temperature": ["mirek": preset.mirek],
            "dynamics":          ["duration": 800]
        ]
        await withTaskGroup(of: Void.self) { group in
            for item in targets {
                guard let glID = item.groupedLightId,
                      let creds = credentials(for: item.bridgeID) else { continue }
                let gid = glID
                group.addTask {
                    await self.patch(id: gid, body: body, ip: creds.ip, token: creds.token)
                }
            }
        }
        saveToLocalCache()
    }

    // MARK: - All Off

    func allOff() async {
        for i in rooms.indices { rooms[i].isOn = false }
        for i in zones.indices { zones[i].isOn = false }
        let body: [String: Any] = ["on": ["on": false]]
        await withTaskGroup(of: Void.self) { group in
            for item in allGroups {
                guard let glID = item.groupedLightId,
                      let creds = credentials(for: item.bridgeID) else { continue }
                let gid = glID
                group.addTask {
                    await self.patch(id: gid, body: body, ip: creds.ip, token: creds.token)
                }
            }
        }
        saveToLocalCache()
    }

    // MARK: - Recall Scene

    func recallScene(_ scene: WatchScene) async {
        guard let creds = credentials(for: scene.bridgeID) else { return }
        // Optimistically mark the owning group on — reverted if the write dies.
        let prevRoomOn = rooms.first(where: { $0.id == scene.ownerGroupID })?.isOn
        let prevZoneOn = zones.first(where: { $0.id == scene.ownerGroupID })?.isOn
        if let idx = rooms.firstIndex(where: { $0.id == scene.ownerGroupID }) { rooms[idx].isOn = true }
        if let idx = zones.firstIndex(where: { $0.id == scene.ownerGroupID }) { zones[idx].isOn = true }
        guard let url = URL(string: "https://\(creds.ip)/clip/v2/resource/scene/\(scene.id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(creds.token,        forHTTPHeaderField: "hue-application-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["recall": ["action": "active"]])
        let ok: Bool
        if let (_, response) = try? await Self.bridgeSession.data(for: req),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            ok = true
        } else {
            ok = false
        }
        if ok {
            saveToLocalCache()
        } else {
            if let prev = prevRoomOn,
               let idx = rooms.firstIndex(where: { $0.id == scene.ownerGroupID }) { rooms[idx].isOn = prev }
            if let prev = prevZoneOn,
               let idx = zones.firstIndex(where: { $0.id == scene.ownerGroupID }) { zones[idx].isOn = prev }
        }
    }

    // MARK: - Refresh from bridges (bounded, multi-bridge)

    /// Pull fresh grouped_light state from every known bridge (bounded per bridge,
    /// concurrent) and merge into rooms/zones. Call on watch-app foreground so the
    /// UI reflects reality instead of drifting between phone pushes.
    func refreshFromBridges() async {
        let creds = uniqueBridgeCredentials()
        guard !creds.isEmpty else { return }
        var fresh: [String: (on: Bool, brightness: Double)] = [:]
        await withTaskGroup(of: [String: (Bool, Double)].self) { group in
            for c in creds {
                group.addTask { await Self.fetchGroupedLights(ip: c.ip, token: c.token, budget: 4) }
            }
            for await partial in group {
                for (k, v) in partial { fresh[k] = v }
            }
        }
        guard !fresh.isEmpty else { return }
        func merge(_ list: inout [WatchRoom]) {
            for i in list.indices {
                if let glID = list[i].groupedLightId, let gl = fresh[glID] {
                    list[i].isOn = gl.on
                    list[i].brightness = gl.brightness > 0 ? gl.brightness : list[i].brightness
                }
            }
        }
        merge(&rooms); merge(&zones)
        saveToLocalCache()
    }

    /// One credential per distinct bridge IP (avoids hitting the same bridge twice).
    private func uniqueBridgeCredentials() -> [WatchBridgeCredentials] {
        var seen = Set<String>()
        var out: [WatchBridgeCredentials] = []
        for c in bridges.values where !seen.contains(c.ip) { seen.insert(c.ip); out.append(c) }
        if out.isEmpty, let ip = bridgeIP, let token = token {
            out.append(WatchBridgeCredentials(bridgeID: "legacy-default", ip: ip, token: token))
        }
        return out
    }

    /// GET all grouped_light states from one bridge, bounded to `budget` seconds.
    /// Returns [groupedLightId: (on, brightness 1–100)]. Empty on timeout/error.
    private static func fetchGroupedLights(ip: String, token: String, budget: TimeInterval) async -> [String: (Bool, Double)] {
        let fetch = Task { () -> [String: (Bool, Double)] in
            guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light") else { return [:] }
            var req = URLRequest(url: url, timeoutInterval: budget)
            req.setValue(token, forHTTPHeaderField: "hue-application-key")
            let (data, _) = try await bridgeSession.data(for: req)
            struct Resp: Decodable {
                struct GL: Decodable {
                    let id: String
                    let on: On
                    let dimming: Dim?
                    struct On: Decodable { let on: Bool }
                    struct Dim: Decodable { let brightness: Double }
                }
                let data: [GL]
            }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            var out: [String: (Bool, Double)] = [:]
            for gl in decoded.data { out[gl.id] = (gl.on.on, gl.dimming?.brightness ?? 0) }
            return out
        }
        let reaper = Task { try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000)); fetch.cancel() }
        defer { reaper.cancel() }
        return (try? await fetch.value) ?? [:]
    }

    // MARK: - Network

    // One shared session with the pinned bridge trust delegate (M-01/D-016);
    // pins arrive from the phone via WCSession ("wc_pins_v1") and are read
    // from the watch-local BridgePinStore on every challenge.
    private static let bridgeSession = URLSession(
        configuration: .default,
        delegate: BridgePinnedTrustDelegate.shared,
        delegateQueue: nil
    )

    /// True only when the bridge acknowledged with a 2xx — callers use it to
    /// decide whether an optimistic flip may be persisted.
    @discardableResult
    private func patch(id: String, body: [String: Any], ip: String, token: String) async -> Bool {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light/\(id)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token,              forHTTPHeaderField: "hue-application-key")
        req.httpBody  = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await Self.bridgeSession.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
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

        let ip = applicationContext["wc_bridge_ip"] as? String ?? ""
        let bridgesData = applicationContext["wc_bridges_v1"] as? Data
        let bridgeMap: [String: WatchBridgeCredentials]? = bridgesData.flatMap {
            try? JSONDecoder().decode([String: WatchBridgeCredentials].self, from: $0)
        }

        // Forget-all (L-30): ONLY the explicit wc_unpaired flag wipes the
        // watch. An empty credential map is never treated as a signal — the
        // phone can legitimately push one during a transient Keychain read
        // failure or in legacy single-bridge mode, and wiping on it would
        // destroy the watch's only credentials + TLS pins.
        if applicationContext["wc_unpaired"] as? Bool == true {
            Self.clearAllStoredData()
            Task { @MainActor [weak self] in
                self?.rooms    = []
                self?.zones    = []
                self?.isPaired = false
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }

        // Decode zones (optional — older payloads may not include them)
        let decodedZones: [WatchRoom]
        if let zonesData = applicationContext["wc_zones_v1"] as? Data,
           let z = try? JSONDecoder().decode([WatchRoom].self, from: zonesData) {
            decodedZones = z
        } else {
            decodedZones = []
        }

        // Decode scenes (optional)
        let decodedScenes: [WatchScene]
        if let scenesData = applicationContext["wc_scenes_v1"] as? Data,
           let s = try? JSONDecoder().decode([WatchScene].self, from: scenesData) {
            decodedScenes = s
        } else {
            decodedScenes = []
        }

        // UserDefaults is thread-safe — write directly from any thread.
        // Credentials go to the watch Keychain, never UserDefaults (D-018).
        UserDefaults.standard.set(roomsData, forKey: "wc_rooms_v1")
        if let zonesData = applicationContext["wc_zones_v1"] as? Data {
            UserDefaults.standard.set(zonesData, forKey: "wc_zones_v1")
        }
        if let scenesData = applicationContext["wc_scenes_v1"] as? Data {
            UserDefaults.standard.set(scenesData, forKey: "wc_scenes_v1")
        }
        // Never clobber stored credentials with an empty/undecodable map.
        if let bridgesData, let bridgeMap, !bridgeMap.isEmpty {
            SharedKeychainStore.save(bridgesData, account: CacheKey.bridges)
        }
        if !ip.isEmpty { UserDefaults.standard.set(ip, forKey: "wc_bridge_ip") }

        // TLS pins pushed alongside credentials (D-016) — required before any
        // watch → bridge HTTPS call can pass the pinned trust evaluation.
        if let pinsData = applicationContext[BridgePinStore.storageKey] as? Data {
            BridgePinStore.shared.ingest(externalData: pinsData)
        }

        // Mirror into watch-side App Group so complications refresh immediately
        // (display data only — no credentials).
        let watchGroup = UserDefaults(suiteName: "group.com.huehome.pro")
        watchGroup?.set(roomsData, forKey: "hue_widget_rooms_v1")
        if let zonesData = applicationContext["wc_zones_v1"] as? Data {
            watchGroup?.set(zonesData, forKey: "hue_widget_zones_v1")
        }
        if let scenesData = applicationContext["wc_scenes_v1"] as? Data {
            watchGroup?.set(scenesData, forKey: "hue_widget_scenes_v1")
        }
        watchGroup?.set(Date(),    forKey: "hue_widget_updated_at")
        if !ip.isEmpty { watchGroup?.set(ip, forKey: "hue_widget_bridge_ip") }

        // Update published properties on MainActor + reload complications
        Task { @MainActor [weak self] in
            self?.rooms    = decoded
            self?.zones    = decodedZones
            self?.scenes   = decodedScenes
            self?.isPaired = !(decoded.isEmpty && decodedZones.isEmpty) || !ip.isEmpty || bridgesData != nil
            self?.lastSyncedAt = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Wipe credentials (watch Keychain), caches, and App Group mirrors.
    nonisolated private static func clearAllStoredData() {
        SharedKeychainStore.delete(account: CacheKey.bridges)
        SharedKeychainStore.delete(account: CacheKey.token)
        let ud = UserDefaults.standard
        ud.removeObject(forKey: CacheKey.rooms)
        ud.removeObject(forKey: "wc_zones_v1")
        ud.removeObject(forKey: "wc_scenes_v1")
        ud.removeObject(forKey: CacheKey.bridgeIP)
        ud.removeObject(forKey: CacheKey.token)
        ud.removeObject(forKey: CacheKey.bridges)
        BridgePinStore.shared.removeAll()
        let group = UserDefaults(suiteName: "group.com.huehome.pro")
        for key in ["hue_widget_rooms_v1", "hue_widget_zones_v1", "hue_widget_scenes_v1",
                    "hue_widget_updated_at", "hue_widget_bridge_ip",
                    "hue_widget_token", "hue_widget_bridges_v1"] {
            group?.removeObject(forKey: key)
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { debugLog("WatchStore WCSession: activation error — \(error)") }
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

/// DEBUG-only console diagnostics (house convention — see UnifiedOrchestrator).
/// Release builds compile the call away.
fileprivate func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
