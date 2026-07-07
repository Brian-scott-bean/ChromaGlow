// SharedKeychainStore.swift
// ChromaGlow — audit M-02/L-30, Decision D-018.
//
// Raw-Data Keychain store scoped to the shared keychain access group so the
// main app, widget extension, and watch app read bridge secrets from the
// Keychain instead of App Group / plain UserDefaults plists.
//
// Compiled into: HueHome (app), HueHomeWidgetExtension, LightShadeWatchApp
// Watch App. Each of those targets carries the matching
// `keychain-access-groups` entitlement: $(AppIdentifierPrefix)com.huehome.pro.shared.
//
// On watchOS the group is local to the watch (keychain access groups never
// span devices); credentials still arrive over WCSession and are persisted
// here instead of UserDefaults.

import Foundation
import Security

// nonisolated: stateless statics over thread-safe SecItem C APIs. Inert in the
// app/widget targets; in the watch target (default actor isolation = MainActor)
// this keeps the WCSession-delegate call sites legal without hopping actors.
nonisolated enum SharedKeychainStore {

    /// LIVE Keychain service identifier — do NOT rename (AGENTS.md identity
    /// list): renaming orphans every existing user's stored credentials.
    static let service = "com.lightshade.app"

    /// Team-prefixed shared access group. The prefix is the Apple team ID
    /// (DEVELOPMENT_TEAM 2H9J347H3T) because $(AppIdentifierPrefix) is only
    /// resolved at signing time and has no runtime equivalent. Must match the
    /// keychain-access-groups entitlement on every target that links this file.
    static let accessGroup = "2H9J347H3T.com.huehome.pro.shared"

    /// Account for the shared multi-bridge credential map
    /// ([bridgeRecordID: WidgetBridgeCredentials] JSON) written by the main
    /// app and read by the widget/Siri surfaces.
    static let bridgeCredentialsAccount = "hue_shared_bridge_credentials_v1"

    // ──────────────────────────────────────────────
    // MARK: - Data API
    // ──────────────────────────────────────────────

    /// Upsert into the shared access group.
    /// AfterFirstUnlock (not WhenUnlocked): widget taps, Siri, and watch
    /// pushes must work while the device is locked. ThisDeviceOnly +
    /// non-synchronizable keeps the token out of iCloud Keychain and restores.
    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        // Delete any existing copy in ANY accessible group first, so a
        // pre-migration item in the app's private group cannot shadow the
        // shared one.
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:               kSecClassGenericPassword,
            kSecAttrService:         service,
            kSecAttrAccount:         account,
            kSecAttrAccessGroup:     accessGroup,
            kSecValueData:           data,
            kSecAttrAccessible:      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable:  false,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Read without qualifying the access group so items that have not been
    /// migrated into the shared group yet are still found (main-app process).
    static func load(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete from every accessible group (shared and legacy private copies).
    static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // ──────────────────────────────────────────────
    // MARK: - String convenience
    // ──────────────────────────────────────────────

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, account: account)
    }

    static func loadString(account: String) -> String? {
        guard let data = load(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
