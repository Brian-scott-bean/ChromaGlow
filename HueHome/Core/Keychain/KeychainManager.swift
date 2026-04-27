// KeychainManager.swift
// HueHome Pro — Epic 1 / Story 1.1
//
// Thread-safe Keychain wrapper.
// Stores and retrieves the Hue Bridge API token using kSecClassGenericPassword.
// All operations throw typed KeychainError so callers can log / surface failures precisely.

import Foundation
import Security
import OSLog

// MARK: - Error Types

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case itemNotFound
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .encodingFailed:           return "KeychainManager: Failed to encode data."
        case .saveFailed(let s):        return "KeychainManager: Save failed — OSStatus \(s)."
        case .readFailed(let s):        return "KeychainManager: Read failed — OSStatus \(s)."
        case .deleteFailed(let s):      return "KeychainManager: Delete failed — OSStatus \(s)."
        case .itemNotFound:             return "KeychainManager: Item not found in Keychain."
        case .unexpectedData:           return "KeychainManager: Retrieved data was in an unexpected format."
        }
    }
}

// MARK: - KeychainManager

final class KeychainManager: @unchecked Sendable {

    // MARK: Singleton
    static let shared = KeychainManager()
    private init() {}

    // MARK: Logger
    private let log = Logger(subsystem: "com.lightshade.app", category: "Keychain")

    // MARK: Keys
    private enum Keys {
        static let apiToken     = "hue_api_token"    // legacy single-bridge
        static let bridgeIP     = "hue_bridge_ip"    // legacy single-bridge
        static let serviceName  = "com.huehome.pro"
        // Multi-bridge keys are namespaced: hue_bridge_<uuid>_ip / hue_bridge_<uuid>_token
        static func ip(for bridgeID: String)    -> String { "hue_bridge_\(bridgeID)_ip" }
        static func token(for bridgeID: String) -> String { "hue_bridge_\(bridgeID)_token" }
        static func clientKey(for bridgeID: String) -> String { "hue_bridge_\(bridgeID)_clientkey" }
    }

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    /// Save (or update) the Hue API token in the Keychain.
    func saveAPIToken(_ token: String) throws {
        log.info("💾 Saving API token to Keychain.")
        try save(value: token, for: Keys.apiToken)
    }

    /// Retrieve the Hue API token from the Keychain.
    func loadAPIToken() throws -> String {
        log.info("🔑 Loading API token from Keychain.")
        return try load(for: Keys.apiToken)
    }

    /// Delete the Hue API token from the Keychain.
    func deleteAPIToken() throws {
        log.info("🗑️ Deleting API token from Keychain.")
        try delete(for: Keys.apiToken)
    }

    /// Save (or update) the Bridge IP address in the Keychain.
    func saveBridgeIP(_ ip: String) throws {
        log.info("💾 Saving Bridge IP (\(ip)) to Keychain.")
        try save(value: ip, for: Keys.bridgeIP)
    }

    /// Retrieve the Bridge IP address from the Keychain.
    func loadBridgeIP() throws -> String {
        log.info("🔑 Loading Bridge IP from Keychain.")
        return try load(for: Keys.bridgeIP)
    }

    /// Delete the Bridge IP address from the Keychain.
    func deleteBridgeIP() throws {
        log.info("🗑️ Deleting Bridge IP from Keychain.")
        try delete(for: Keys.bridgeIP)
    }

    // ──────────────────────────────────────────────
    // MARK: - Multi-Bridge Credential API (Stage 2A)
    // ──────────────────────────────────────────────

    /// Store credentials for a specific bridge by its UUID.
    func saveCredentials(ip: String, token: String, clientKey: String? = nil, for bridgeID: String) throws {
        log.info("💾 Saving credentials for bridge \(bridgeID).")
        try save(value: ip,    for: Keys.ip(for: bridgeID))
        try save(value: token, for: Keys.token(for: bridgeID))
        if let ck = clientKey, !ck.isEmpty {
            try save(value: ck, for: Keys.clientKey(for: bridgeID))
        }
    }

    /// Retrieve ip + token for a specific bridge UUID.
    func loadCredentials(for bridgeID: String) throws -> (ip: String, token: String) {
        let ip    = try load(for: Keys.ip(for: bridgeID))
        let token = try load(for: Keys.token(for: bridgeID))
        return (ip, token)
    }

    /// Load entertainment client key for a bridge.
    func loadClientKey(for bridgeID: String) -> String? {
        try? load(for: Keys.clientKey(for: bridgeID))
    }

    /// Remove all credentials for a bridge.
    func deleteCredentials(for bridgeID: String) {
        try? delete(for: Keys.ip(for: bridgeID))
        try? delete(for: Keys.token(for: bridgeID))
        try? delete(for: Keys.clientKey(for: bridgeID))
        log.info("🗑️ Deleted credentials for bridge \(bridgeID).")
    }

    /// Migrate legacy single-bridge Keychain entries into a new BridgeRecord.
    /// Returns the migrated (ip, token) pair if found, nil if already migrated or missing.
    /// Call once on first launch after Stage 2A upgrade.
    func migrateLegacyCredentials(to bridgeID: String) -> (ip: String, token: String)? {
        guard let ip    = try? load(for: Keys.bridgeIP),
              let token = try? load(for: Keys.apiToken),
              !ip.isEmpty, !token.isEmpty else {
            log.info("ℹ️  No legacy credentials found to migrate.")
            return nil
        }
        do {
            try saveCredentials(ip: ip, token: token, for: bridgeID)
            // Transfer client key if present
            if let ck = try? load(for: "hue_client_key") {
                try save(value: ck, for: Keys.clientKey(for: bridgeID))
            }
            // Delete legacy keys
            try? delete(for: Keys.apiToken)
            try? delete(for: Keys.bridgeIP)
            try? delete(for: "hue_client_key")
            log.info("✅ Migrated legacy credentials to bridge ID \(bridgeID).")
            return (ip, token)
        } catch {
            log.error("❌ Migration failed: \(error.localizedDescription)")
            return nil
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Generic Key Access (internal)
    // ──────────────────────────────────────────────

    /// Save any string value under an arbitrary Keychain key.
    /// Used by the ViewModel to persist the Entertainment client key.
    func save(value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Attempt to delete any existing item before writing (upsert pattern).
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Keys.serviceName,
            kSecAttrAccount: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:                  kSecClassGenericPassword,
            kSecAttrService:            Keys.serviceName,
            kSecAttrAccount:            key,
            kSecValueData:              data,
            kSecAttrAccessible:         kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("❌ Keychain save failed for key '\(key)' — OSStatus: \(status)")
            throw KeychainError.saveFailed(status)
        }
        log.debug("✅ Keychain save succeeded for key '\(key)'.")
    }

    func load(for key: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Keys.serviceName,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            log.warning("⚠️ Keychain item not found for key '\(key)'.")
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else {
            log.error("❌ Keychain read failed for key '\(key)' — OSStatus: \(status)")
            throw KeychainError.readFailed(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        log.debug("✅ Keychain load succeeded for key '\(key)'.")
        return string
    }

    func delete(for key: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Keys.serviceName,
            kSecAttrAccount: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("❌ Keychain delete failed for key '\(key)' — OSStatus: \(status)")
            throw KeychainError.deleteFailed(status)
        }
        log.debug("✅ Keychain delete succeeded for key '\(key)'.")
    }
}
