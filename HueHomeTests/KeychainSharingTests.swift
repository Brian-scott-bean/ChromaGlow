// KeychainSharingTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-02 / L-30 (Decision D-018):
//  - Keychain writes use AfterFirstUnlockThisDeviceOnly and are
//    non-synchronizable (never in iCloud Keychain).
//  - The bridge token is never persisted in the App Group UserDefaults suite;
//    only non-secret routing metadata (bridge id, ip) lives there.
//  - The entertainment client key structurally cannot enter
//    WidgetBridgeCredentials (the only credential shape shared with
//    widget/Siri/watch surfaces).
//  - Forget-all clears the shared credential surface and credentials(for:)
//    returns nil afterwards.
//  - The pre-D-018 legacy-item migration re-homes items without losing their
//    values.
//  - BridgePinStore no longer leaves plaintext pin mirrors in UserDefaults.
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Credential storage".

import XCTest
import Security
@testable import HueHome

final class KeychainSharingTests: XCTestCase {

    private static let appGroupSuite = "group.com.huehome.pro"
    private static let sentinelToken = "KCTEST-TOKEN-f00dfacef00dface-KCTEST"

    // Snapshot the real shared credential blob + App Group keys so the suite
    // can never clobber an actual pairing on the machine running it.
    private var savedBlob: Data?
    private var savedGroupDomain: [String: Any]?

    override func setUp() {
        super.setUp()
        savedBlob = SharedKeychainStore.load(account: SharedKeychainStore.bridgeCredentialsAccount)
        savedGroupDomain = UserDefaults(suiteName: Self.appGroupSuite)?
            .persistentDomain(forName: Self.appGroupSuite)
    }

    override func tearDown() {
        if let savedBlob {
            SharedKeychainStore.save(savedBlob, account: SharedKeychainStore.bridgeCredentialsAccount)
        } else {
            SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
        }
        if let ud = UserDefaults(suiteName: Self.appGroupSuite) {
            ud.setPersistentDomain(savedGroupDomain ?? [:], forName: Self.appGroupSuite)
        }
        super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - Accessibility / synchronizability (audit §6)
    // ──────────────────────────────────────────────

    func testKeychainWritesUseAfterFirstUnlockThisDeviceOnlyAndNonSyncable() throws {
        let key = "kc_test_accessibility_probe"
        defer { try? KeychainManager.shared.delete(for: key) }
        try KeychainManager.shared.save(value: "probe", for: key)

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      "com.lightshade.app",
            kSecAttrAccount:      key,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [CFString: Any])

        XCTAssertEqual(attrs[kSecAttrAccessible] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "D-018 requires AfterFirstUnlockThisDeviceOnly so widget/Siri/watch work from the lock screen")
        XCTAssertNotEqual(attrs[kSecAttrSynchronizable] as? Bool, true,
                          "Bridge credentials must never be iCloud-synchronizable")
    }

    func testSharedKeychainStoreWritesAfterFirstUnlockNonSyncable() throws {
        let account = "kc_test_shared_probe"
        defer { SharedKeychainStore.delete(account: account) }
        XCTAssertTrue(SharedKeychainStore.save("probe", account: account))

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      SharedKeychainStore.service,
            kSecAttrAccount:      account,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [CFString: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attrs[kSecAttrSynchronizable] as? Bool, true)
    }

    // ──────────────────────────────────────────────
    // MARK: - Legacy item migration (D-018 upgrade safety)
    // ──────────────────────────────────────────────

    func testMigrationRehomesLegacyItemWithoutLosingValue() throws {
        let key = "kc_test_legacy_migration_probe"
        defer { try? KeychainManager.shared.delete(for: key) }

        // Plant a pre-P1-style item: WhenUnlocked accessibility, no explicit
        // access group (exactly what the P0 KeychainManager wrote).
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "com.lightshade.app",
            kSecAttrAccount: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let legacyAdd: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    "com.lightshade.app",
            kSecAttrAccount:    key,
            kSecValueData:      Data("legacy-value".utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        XCTAssertEqual(SecItemAdd(legacyAdd as CFDictionary, nil), errSecSuccess)

        KeychainManager.shared.migrateToSharedAccessGroupIfNeeded()

        // Value must survive and the item must now carry the new accessibility.
        XCTAssertEqual(try KeychainManager.shared.load(for: key), "legacy-value")
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      "com.lightshade.app",
            kSecAttrAccount:      key,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attrs = try XCTUnwrap(result as? [CFString: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    // ──────────────────────────────────────────────
    // MARK: - No token in the App Group suite (audit §6)
    // ──────────────────────────────────────────────

    func testTokenIsNeverWrittenToAppGroupDefaults() throws {
        let store = WidgetDataStore.shared
        store.write(bridges: [
            "test-bridge": WidgetBridgeCredentials(bridgeID: "test-bridge",
                                                   ip: "192.0.2.1",
                                                   token: Self.sentinelToken)
        ])

        let ud = try XCTUnwrap(UserDefaults(suiteName: Self.appGroupSuite))
        let domain = ud.persistentDomain(forName: Self.appGroupSuite) ?? [:]
        for (key, value) in domain {
            let rendered: String
            if let data = value as? Data {
                rendered = String(decoding: data, as: UTF8.self)
            } else {
                rendered = String(describing: value)
            }
            XCTAssertFalse(rendered.contains(Self.sentinelToken),
                           "App Group key '\(key)' contains the bridge token — M-02 regression")
        }
        // Legacy plaintext keys must be gone, routing metadata present.
        XCTAssertNil(ud.object(forKey: "hue_widget_token"))
        XCTAssertNil(ud.object(forKey: "hue_widget_bridges_v1"))
        XCTAssertEqual(store.routing["test-bridge"]?.ip, "192.0.2.1")

        // The credential path still works — via the Keychain.
        XCTAssertEqual(store.credentials(for: "test-bridge")?.token, Self.sentinelToken)
        XCTAssertTrue(store.isPaired)
    }

    // ──────────────────────────────────────────────
    // MARK: - Upgrade window: legacy App Group fallback (read-only)
    // ──────────────────────────────────────────────

    func testUpgradeWindowFallsBackToLegacyAppGroupCredentials() throws {
        // Snapshot the REAL legacy single-bridge slots so this test can never
        // destroy an actual pairing on the machine running the suite.
        let savedLegacyIP    = SharedKeychainStore.load(account: "hue_bridge_ip")
        let savedLegacyToken = SharedKeychainStore.load(account: "hue_api_token")
        defer {
            if let savedLegacyIP { SharedKeychainStore.save(savedLegacyIP, account: "hue_bridge_ip") }
            if let savedLegacyToken { SharedKeychainStore.save(savedLegacyToken, account: "hue_api_token") }
        }

        // Simulate "app updated but not launched yet": no shared-Keychain
        // blob, pre-D-018 plaintext copies still in the App Group.
        SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
        SharedKeychainStore.delete(account: "hue_bridge_ip")
        SharedKeychainStore.delete(account: "hue_api_token")
        let ud = try XCTUnwrap(UserDefaults(suiteName: Self.appGroupSuite))
        let legacy = ["legacy-b": WidgetBridgeCredentials(bridgeID: "legacy-b",
                                                          ip: "192.0.2.7",
                                                          token: Self.sentinelToken)]
        ud.set(try JSONEncoder().encode(legacy), forKey: "hue_widget_bridges_v1")
        ud.set("192.0.2.7", forKey: "hue_widget_bridge_ip")

        let store = WidgetDataStore.shared
        XCTAssertEqual(store.credentials(for: "legacy-b")?.token, Self.sentinelToken,
            "the widget must keep working between app update and first app launch")
        XCTAssertEqual(store.primaryCredentials()?.ip, "192.0.2.7")

        // The app's first publish scrubs the plaintext copies — the fallback
        // must then be dead and the Keychain copy authoritative.
        store.write(bridges: ["new-b": WidgetBridgeCredentials(bridgeID: "new-b",
                                                               ip: "192.0.2.8",
                                                               token: "NEW-TOKEN")])
        XCTAssertNil(ud.object(forKey: "hue_widget_bridges_v1"))
        XCTAssertNil(store.credentials(for: "legacy-b"))
        XCTAssertEqual(store.credentials(for: "new-b")?.token, "NEW-TOKEN")
    }

    // ──────────────────────────────────────────────
    // MARK: - Entertainment client key stays out of shared shapes (audit §6)
    // ──────────────────────────────────────────────

    func testWidgetBridgeCredentialsCarriesNoClientKey() {
        let creds = WidgetBridgeCredentials(bridgeID: "b", ip: "192.0.2.1", token: "t")
        let labels = Mirror(reflecting: creds).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), Set(["bridgeID", "ip", "token"]),
                       "WidgetBridgeCredentials is the only shape shared with widget/Siri/WCSession — the entertainment client key must never be added to it")
    }

    // ──────────────────────────────────────────────
    // MARK: - Forget-all clears the shared surface (audit §6)
    // ──────────────────────────────────────────────

    func testForgetAllClearsSharedCredentialSurface() throws {
        let store = WidgetDataStore.shared
        store.write(bridges: [
            "test-bridge": WidgetBridgeCredentials(bridgeID: "test-bridge",
                                                   ip: "192.0.2.1",
                                                   token: Self.sentinelToken)
        ])
        store.write(rooms: [WidgetRoomSnapshot(id: "r1", name: "Test Room", archetype: nil,
                                               isOn: true, brightness: 50, lightCount: 1,
                                               groupedLightId: "gl1", bridgeID: "test-bridge")])
        XCTAssertNotNil(store.credentials(for: "test-bridge"))

        store.clearAll()

        XCTAssertNil(store.credentials(for: "test-bridge"),
                     "credentials(for:) must return nil after forget-all")
        XCTAssertTrue(store.bridges.isEmpty)
        XCTAssertTrue(store.rooms.isEmpty)
        XCTAssertTrue(store.routing.isEmpty)
        XCTAssertFalse(store.isPaired)
        XCTAssertNil(SharedKeychainStore.load(account: SharedKeychainStore.bridgeCredentialsAccount))
    }

    // ──────────────────────────────────────────────
    // MARK: - Pin store leaves no plaintext mirrors (D-018 fold-in)
    // ──────────────────────────────────────────────

    func testPinStorePersistScrubsUserDefaultsMirrors() throws {
        let store = BridgePinStore()   // fresh instance — not the shared singleton
        let pin = BridgePin(bridgeID: "ECB5FAFFFE000001",
                            publicKeySHA256: "dGVzdA==",
                            certSHA256: "dGVzdA==",
                            host: "192.0.2.99",
                            pinnedAt: Date())
        store.save(pin: pin)
        defer { store.removePin(bridgeID: pin.bridgeID) }

        XCTAssertEqual(store.pin(forBridgeID: pin.bridgeID)?.publicKeySHA256, pin.publicKeySHA256)
        let groupUD = UserDefaults(suiteName: Self.appGroupSuite)
        XCTAssertNil(groupUD?.data(forKey: BridgePinStore.storageKey),
                     "App Group pin mirror must be scrubbed after persist (D-018)")
        XCTAssertNil(UserDefaults.standard.data(forKey: BridgePinStore.storageKey),
                     "standard-defaults pin mirror must be scrubbed after persist (D-018)")
    }
}
