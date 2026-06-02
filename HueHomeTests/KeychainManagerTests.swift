// KeychainManagerTests.swift
// HueHome Pro — Unit Tests
//
// Tests for KeychainManager save / load / delete round-trips.
// Uses a unique service name suffix per test run to avoid collisions with the live app.

import XCTest
@testable import HueHome

final class KeychainManagerTests: XCTestCase {

    let keychain = KeychainManager.shared

    // Unique per-test keys to prevent cross-test contamination
    var tokenKey: String { "test_token_\(name)" }
    var ipKey:    String { "test_ip_\(name)" }

    override func tearDownWithError() throws {
        try? keychain.delete(for: tokenKey)
        try? keychain.delete(for: ipKey)
    }

    // MARK: - API Token

    func testSaveAndLoadAPIToken() throws {
        try keychain.saveAPIToken("my-secret-token")
        let loaded = try keychain.loadAPIToken()
        XCTAssertEqual(loaded, "my-secret-token")
    }

    func testOverwriteAPIToken() throws {
        try keychain.saveAPIToken("first-token")
        try keychain.saveAPIToken("second-token")
        let loaded = try keychain.loadAPIToken()
        XCTAssertEqual(loaded, "second-token", "Second save should overwrite the first")
    }

    func testDeleteAPIToken() throws {
        try keychain.saveAPIToken("delete-me")
        try keychain.deleteAPIToken()
        XCTAssertThrowsError(try keychain.loadAPIToken()) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected itemNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Bridge IP

    func testSaveAndLoadBridgeIP() throws {
        try keychain.saveBridgeIP("192.168.1.100")
        let loaded = try keychain.loadBridgeIP()
        XCTAssertEqual(loaded, "192.168.1.100")
    }

    // MARK: - Generic Key

    func testGenericSaveLoad() throws {
        try keychain.save(value: "generic-value", for: "test_generic_key")
        let loaded = try keychain.load(for: "test_generic_key")
        XCTAssertEqual(loaded, "generic-value")
        try? keychain.delete(for: "test_generic_key")
    }

    // MARK: - Error Cases

    func testLoadMissingKeyThrowsItemNotFound() {
        XCTAssertThrowsError(try keychain.load(for: "non_existent_key_\(UUID().uuidString)")) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected itemNotFound")
                return
            }
        }
    }

    func testDeleteNonExistentKeyDoesNotThrow() {
        // Should not throw even if key doesn't exist
        XCTAssertNoThrow(try keychain.delete(for: "non_existent_\(UUID().uuidString)"))
    }
}
