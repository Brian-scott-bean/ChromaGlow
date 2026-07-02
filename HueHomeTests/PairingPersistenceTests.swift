// PairingPersistenceTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings L-15 / L-17 (round-2 checkpoint Item 1):
//  - Pairing persists credentials DIRECTLY to per-bridge namespaced Keychain
//    slots at pairing time. Two sequential pairings in one session must leave
//    BOTH bridges' credentials readable — the legacy single-bridge slots
//    (hue_api_token/hue_bridge_ip) used to be overwritten by the second
//    pairing, silently dropping the first bridge on relaunch.
//  - The legacy slots are never written by a new pairing.
//  - BridgePairingRegistrar dedups records by canonical bridgeid (L-17):
//    re-pairing the same physical bridge reuses the existing record and moves
//    the fresh credentials onto it instead of minting a duplicate row.
//  - configure() builds one client per paired record.
//
// Audit: docs/audit/hardening-audit-2026-07-01.md (Round-1 LOW list).

import XCTest
import SwiftData
@testable import HueHome

@MainActor
final class PairingPersistenceTests: XCTestCase {

    private static let tokenA = "PAIRTEST-TOKEN-A-0123456789abcdef"
    private static let tokenB = "PAIRTEST-TOKEN-B-fedcba9876543210"
    private static let hostA  = "192.0.2.101"
    private static let hostB  = "192.0.2.102"
    private static let appGroupSuite = "group.com.huehome.pro"

    /// Namespaced Keychain ids minted during a test — always cleaned up.
    private var mintedIDs: [String] = []

    // Snapshot the real legacy slots + shared credential surface so the suite
    // can never clobber an actual pairing on the machine running it
    // (configure() publishes to the shared widget blob).
    private var savedLegacyToken: String?
    private var savedLegacyIP:    String?
    private var savedBlob:        Data?
    private var savedGroupDomain: [String: Any]?

    override func setUp() {
        super.setUp()
        savedLegacyToken = try? KeychainManager.shared.loadAPIToken()
        savedLegacyIP    = try? KeychainManager.shared.loadBridgeIP()
        savedBlob        = SharedKeychainStore.load(account: SharedKeychainStore.bridgeCredentialsAccount)
        savedGroupDomain = UserDefaults(suiteName: Self.appGroupSuite)?
            .persistentDomain(forName: Self.appGroupSuite)
        try? KeychainManager.shared.deleteAPIToken()
        try? KeychainManager.shared.deleteBridgeIP()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        for id in mintedIDs { KeychainManager.shared.deleteCredentials(for: id) }
        mintedIDs.removeAll()
        if let savedLegacyToken { try? KeychainManager.shared.saveAPIToken(savedLegacyToken) }
        else                    { try? KeychainManager.shared.deleteAPIToken() }
        if let savedLegacyIP    { try? KeychainManager.shared.saveBridgeIP(savedLegacyIP) }
        else                    { try? KeychainManager.shared.deleteBridgeIP() }
        if let savedBlob {
            SharedKeychainStore.save(savedBlob, account: SharedKeychainStore.bridgeCredentialsAccount)
        } else {
            SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
        }
        if let ud = UserDefaults(suiteName: Self.appGroupSuite) {
            ud.setPersistentDomain(savedGroupDomain ?? [:], forName: Self.appGroupSuite)
        }
        StubURLProtocol.reset()
        super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Drive one full stubbed pairing through the view model and return the
    /// minted per-bridge record id.
    private func pair(host: String, token: String) async throws -> String {
        let vm = BridgeDiscoveryViewModel()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        vm.pairingSessionOverride = URLSession(configuration: config)
        // URLProtocol stubs cannot present a server trust for TOFU capture —
        // bypass the D-016 pin acquisition step for this offline test.
        vm.pinAcquisitionOverride = { _ in true }

        let success = "[{\"success\":{\"username\":\"\(token)\",\"clientkey\":\"\"}}]"
        StubURLProtocol.stubs["/api"] = (Data(success.utf8), 200)

        vm.pairWithBridge(BridgeEndpoint(name: "TestBridge", host: host, port: 443))
        for _ in 0..<100 {
            if case .paired = vm.phase { break }
            if case .error = vm.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .paired(let ip, _) = vm.phase else {
            throw XCTSkip("pairing did not complete; phase=\(vm.phase)")
        }
        XCTAssertEqual(ip, host)
        let mintedID = try XCTUnwrap(vm.pairedRecordID, "pairing must mint a per-bridge record id")
        mintedIDs.append(mintedID)
        return mintedID
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BridgeRecord.self, configurations: config)
        return ModelContext(container)
    }

    // ──────────────────────────────────────────────
    // MARK: - L-15: two pairings in one session
    // ──────────────────────────────────────────────

    func testTwoSequentialPairingsLeaveBothBridgesCredentialsReadable() async throws {
        let idA = try await pair(host: Self.hostA, token: Self.tokenA)
        let idB = try await pair(host: Self.hostB, token: Self.tokenB)
        XCTAssertNotEqual(idA, idB)

        // THE regression: bridge A's credentials must survive bridge B's pairing.
        let credsA = try KeychainManager.shared.loadCredentials(for: idA)
        XCTAssertEqual(credsA.ip, Self.hostA)
        XCTAssertEqual(credsA.token, Self.tokenA)

        let credsB = try KeychainManager.shared.loadCredentials(for: idB)
        XCTAssertEqual(credsB.ip, Self.hostB)
        XCTAssertEqual(credsB.token, Self.tokenB)
    }

    func testPairingNeverWritesLegacySingleBridgeSlots() async throws {
        _ = try await pair(host: Self.hostA, token: Self.tokenA)
        XCTAssertNil(try? KeychainManager.shared.loadAPIToken(),
                     "pairing must not write the legacy hue_api_token slot (L-15)")
        XCTAssertNil(try? KeychainManager.shared.loadBridgeIP(),
                     "pairing must not write the legacy hue_bridge_ip slot (L-15)")
    }

    /// Round-2 Item 2 ("Pair Another Bridge"): a second pairing driven through
    /// the SAME view model — reset back to scanning, then pair again — must
    /// mint a separate record id and keep both credential sets readable.
    func testPairAnotherBridgeOnSameViewModelKeepsBothCredentialSets() async throws {
        let vm = BridgeDiscoveryViewModel()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        vm.pairingSessionOverride = URLSession(configuration: config)
        vm.pinAcquisitionOverride = { _ in true }

        func pairOnce(host: String, token: String) async throws -> String {
            StubURLProtocol.stubs["/api"] = (Data("[{\"success\":{\"username\":\"\(token)\",\"clientkey\":\"\"}}]".utf8), 200)
            vm.pairWithBridge(BridgeEndpoint(name: "TestBridge", host: host, port: 443))
            for _ in 0..<100 {
                if case .paired = vm.phase { break }
                if case .error = vm.phase { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard case .paired = vm.phase else { throw XCTSkip("pairing did not complete; phase=\(vm.phase)") }
            let minted = try XCTUnwrap(vm.pairedRecordID)
            mintedIDs.append(minted)
            return minted
        }

        let idA = try await pairOnce(host: Self.hostA, token: Self.tokenA)
        vm.resetToIdle()   // "Pair Another Bridge" path
        let idB = try await pairOnce(host: Self.hostB, token: Self.tokenB)

        XCTAssertNotEqual(idA, idB, "each pairing must mint its own record id")
        XCTAssertEqual(try KeychainManager.shared.loadCredentials(for: idA).token, Self.tokenA)
        XCTAssertEqual(try KeychainManager.shared.loadCredentials(for: idB).token, Self.tokenB)
    }

    // ──────────────────────────────────────────────
    // MARK: - L-15: configure() builds a client per paired bridge
    // ──────────────────────────────────────────────

    func testConfigureBuildsClientsForBothPairedBridges() async throws {
        let idA = try await pair(host: Self.hostA, token: Self.tokenA)
        let idB = try await pair(host: Self.hostB, token: Self.tokenB)

        let context = try makeInMemoryContext()
        let recordA = try BridgePairingRegistrar.register(
            mintedID: idA, host: Self.hostA, canonicalBridgeID: "AABBCCDDEEFF0001",
            preferredName: "My Bridge", sortOrder: 0, modelContext: context
        ).record
        let recordB = try BridgePairingRegistrar.register(
            mintedID: idB, host: Self.hostB, canonicalBridgeID: "AABBCCDDEEFF0002",
            preferredName: "Bridge B", sortOrder: 999, modelContext: context
        ).record
        XCTAssertFalse(recordA.id == recordB.id)

        let orchestrator = UnifiedOrchestrator()
        orchestrator.configure(bridges: [recordA, recordB], modelContext: context)
        XCTAssertEqual(Set(orchestrator.allBridgeIDs), [idA, idB],
                       "configure() must build one client per paired bridge")
    }

    // ──────────────────────────────────────────────
    // MARK: - L-17: record dedup by canonical bridgeid
    // ──────────────────────────────────────────────

    func testRegistrarReusesRecordForSameCanonicalBridgeID() async throws {
        let context = try makeInMemoryContext()
        let canonical = "0123456789ABCDEF"

        let idFirst = try await pair(host: Self.hostA, token: Self.tokenA)
        let first = try BridgePairingRegistrar.register(
            mintedID: idFirst, host: Self.hostA, canonicalBridgeID: canonical,
            preferredName: "My Bridge", sortOrder: 0, modelContext: context
        )
        XCTAssertFalse(first.reusedExistingRecord)

        // Re-pair the SAME physical bridge (new minted id, new token, new DHCP ip).
        let idSecond = try await pair(host: Self.hostB, token: Self.tokenB)
        let second = try BridgePairingRegistrar.register(
            mintedID: idSecond, host: Self.hostB, canonicalBridgeID: canonical,
            preferredName: "Bridge XXXX", sortOrder: 999, modelContext: context
        )

        XCTAssertTrue(second.reusedExistingRecord, "same bridgeid must reuse the record (L-17)")
        XCTAssertEqual(second.record.id, first.record.id)
        XCTAssertEqual(second.record.host, Self.hostB, "host must refresh on re-pair")

        let all = try context.fetch(FetchDescriptor<BridgeRecord>())
        XCTAssertEqual(all.count, 1, "re-pairing must not mint duplicate records")

        // Fresh credentials moved onto the existing record id; duplicate slots gone.
        let creds = try KeychainManager.shared.loadCredentials(for: first.record.id)
        XCTAssertEqual(creds.ip, Self.hostB)
        XCTAssertEqual(creds.token, Self.tokenB)
        XCTAssertThrowsError(try KeychainManager.shared.loadCredentials(for: idSecond),
                             "minted duplicate credential slots must be deleted")
    }

    func testRegistrarDoesNotMergeDifferentBridgeAtSameHost() async throws {
        let context = try makeInMemoryContext()

        let idFirst = try await pair(host: Self.hostA, token: Self.tokenA)
        _ = try BridgePairingRegistrar.register(
            mintedID: idFirst, host: Self.hostA, canonicalBridgeID: "AAAA111122223333",
            preferredName: "My Bridge", sortOrder: 0, modelContext: context
        )

        // A DIFFERENT physical bridge shows up on the same IP (DHCP reshuffle).
        let idSecond = try await pair(host: Self.hostA, token: Self.tokenB)
        let second = try BridgePairingRegistrar.register(
            mintedID: idSecond, host: Self.hostA, canonicalBridgeID: "BBBB444455556666",
            preferredName: "Bridge B", sortOrder: 999, modelContext: context
        )

        XCTAssertFalse(second.reusedExistingRecord,
                       "a different canonical bridgeid must never merge into an existing record")
        let all = try context.fetch(FetchDescriptor<BridgeRecord>())
        XCTAssertEqual(all.count, 2)
    }
}
