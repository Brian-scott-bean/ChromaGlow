// BridgePinStore.swift
// ChromaGlow — Bridge TLS trust (audit H-01/H-02/M-01, Decision D-016)
//
// Persistence for BridgePins across the three processes that talk to a bridge:
//
//  - Main app:    Keychain (authoritative, integrity-protected) + App Group
//                 UserDefaults mirror so extension processes can read.
//  - Widget/Siri: read the App Group mirror (their own Keychain namespace is
//                 empty until D-018 introduces a shared access group).
//  - watchOS:     standard UserDefaults, populated from the phone via
//                 WCSession applicationContext ("wc_pins_v1").
//
// Pins are public key material — NOT secrets — so the UserDefaults mirrors do
// not violate the credentials-stay-in-Keychain rule. The Keychain copy is
// still written first and read first for tamper resistance in the main app.

import Foundation
import Security

final class BridgePinStore: @unchecked Sendable {

    static let shared = BridgePinStore()

    /// Storage key in every sink (Keychain account, UserDefaults key,
    /// WCSession applicationContext key on the watch side).
    static let storageKey = "hue_bridge_tls_pins_v1"

    /// LIVE Keychain service identifier — do NOT rename (AGENTS.md identity list).
    private static let keychainService = "com.lightshade.app"
    private static let appGroupSuite   = "group.com.huehome.pro"

    private let lock = NSLock()
    private var cache: [BridgePin]?

    init() {}

    // ──────────────────────────────────────────────
    // MARK: - Read
    // ──────────────────────────────────────────────

    func loadPins() -> [BridgePin] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let pins = Self.decode(readData()) ?? []
        cache = pins
        return pins
    }

    func pin(forBridgeID bridgeID: String) -> BridgePin? {
        loadPins().first { $0.bridgeID == bridgeID }
    }

    /// True when some pin already records this host (cheap startup check for
    /// the upgrade-migration path; identity is still the bridgeid, not the host).
    func hasPin(forHost host: String) -> Bool {
        loadPins().contains { $0.host == host }
    }

    // ──────────────────────────────────────────────
    // MARK: - Write
    // ──────────────────────────────────────────────

    /// Upsert by bridgeID.
    func save(pin: BridgePin) {
        lock.lock()
        defer { lock.unlock() }
        var pins = cache ?? Self.decode(readData()) ?? []
        pins.removeAll { $0.bridgeID == pin.bridgeID }
        pins.append(pin)
        persist(pins)
    }

    func removePin(bridgeID: String) {
        lock.lock()
        defer { lock.unlock() }
        var pins = cache ?? Self.decode(readData()) ?? []
        pins.removeAll { $0.bridgeID == bridgeID }
        persist(pins)
    }

    /// Remove every pin recorded for a host (used when a bridge is forgotten —
    /// the caller only knows the record's host, not the canonical bridgeid).
    func removePins(forHost host: String) {
        lock.lock()
        defer { lock.unlock() }
        var pins = cache ?? Self.decode(readData()) ?? []
        pins.removeAll { $0.host == host }
        persist(pins)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        persist([])
    }

    /// Ingest a pin blob pushed from another device (watch ← phone WCSession).
    /// Raw data is stored as-is; the cache refreshes on next read.
    func ingest(externalData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let pins = Self.decode(externalData) else { return }
        persist(pins)
    }

    /// Encoded pins for the WCSession push (phone → watch).
    func encodedPins() -> Data? {
        try? JSONEncoder().encode(loadPins())
    }

    // ──────────────────────────────────────────────
    // MARK: - Sinks (call only with `lock` held)
    // ──────────────────────────────────────────────

    private func readData() -> Data? {
        if let data = keychainRead() { return data }
        if let data = UserDefaults(suiteName: Self.appGroupSuite)?.data(forKey: Self.storageKey) {
            return data
        }
        return UserDefaults.standard.data(forKey: Self.storageKey)
    }

    private func persist(_ pins: [BridgePin]) {
        cache = pins
        guard let data = try? JSONEncoder().encode(pins) else { return }
        keychainWrite(data)
        UserDefaults(suiteName: Self.appGroupSuite)?.set(data, forKey: Self.storageKey)
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func decode(_ data: Data?) -> [BridgePin]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([BridgePin].self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - Keychain (self-contained; extensions fall through harmlessly)
    // ──────────────────────────────────────────────

    private func keychainRead() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.storageKey,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainWrite(_ data: Data) {
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.storageKey,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    Self.keychainService,
            kSecAttrAccount:    Self.storageKey,
            kSecValueData:      data,
            // Pins must be readable during background SSE/widget refreshes.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
