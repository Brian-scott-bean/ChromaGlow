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
    private let log = Logger(subsystem: "com.huehome.pro", category: "Keychain")

    // MARK: Keys
    private enum Keys {
        static let apiToken     = "hue_api_token"
        static let bridgeIP     = "hue_bridge_ip"
        static let serviceName  = "com.huehome.pro"
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
