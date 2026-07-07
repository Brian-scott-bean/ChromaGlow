// BridgePinStore.swift
// ChromaGlow — Bridge TLS trust (audit H-01/H-02/M-01, Decisions D-016/D-018)
//
// Persistence for BridgePins across the three processes that talk to a bridge:
//
//  - Main app + Widget/Siri: shared Keychain access group (D-018) — the same
//    group that carries the bridge credentials, so extensions read pins
//    without any UserDefaults mirror.
//  - watchOS: watch-local Keychain (same code path), populated from the phone
//    via WCSession applicationContext ("hue_bridge_tls_pins_v1").
//
// The pre-D-018 App Group / standard-UserDefaults mirrors are read as
// migration fallbacks only (pins written by a P0 build) and are scrubbed on
// the next persist. Pins are public key material — not secrets — but the
// Keychain copy is integrity-protected and now reachable from every process.

import Foundation

// nonisolated: all state is guarded by the internal NSLock (@unchecked Sendable
// contract below). Inert in the app/widget targets; in the watch target
// (default actor isolation = MainActor) this keeps the TLS-callback and
// WCSession-delegate call sites legal without hopping actors.
nonisolated final class BridgePinStore: @unchecked Sendable {

    static let shared = BridgePinStore()

    /// Storage key in every sink (Keychain account, UserDefaults key,
    /// WCSession applicationContext key on the watch side).
    static let storageKey = "hue_bridge_tls_pins_v1"

    private static let appGroupSuite = "group.com.huehome.pro"

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
        // Migration fallbacks: mirrors written by the P0 build before the
        // shared access group existed. Scrubbed on the next persist.
        if let data = UserDefaults(suiteName: Self.appGroupSuite)?.data(forKey: Self.storageKey) {
            return data
        }
        return UserDefaults.standard.data(forKey: Self.storageKey)
    }

    private func persist(_ pins: [BridgePin]) {
        cache = pins
        guard let data = try? JSONEncoder().encode(pins) else { return }
        // D-018: pins live in the shared Keychain group. The P0-era
        // UserDefaults mirrors are removed only AFTER a verified Keychain
        // write — scrubbing them while the write failed would leave the pins
        // existing nowhere durable and every bridge connection failing TLS at
        // the next launch.
        guard keychainWrite(data) else { return }
        UserDefaults(suiteName: Self.appGroupSuite)?.removeObject(forKey: Self.storageKey)
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private static func decode(_ data: Data?) -> [BridgePin]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([BridgePin].self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - Keychain (via SharedKeychainStore — ONE copy of the D-018
    // attribute contract; extensions fall through harmlessly)
    // ──────────────────────────────────────────────

    private func keychainRead() -> Data? {
        SharedKeychainStore.load(account: Self.storageKey)
    }

    private func keychainWrite(_ data: Data) -> Bool {
        SharedKeychainStore.save(data, account: Self.storageKey)
    }
}
