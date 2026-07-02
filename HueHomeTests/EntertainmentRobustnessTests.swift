// EntertainmentRobustnessTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-06 / M-09 / L-11 (entertainment/DTLS):
//  - M-09: ContinuationGate resumes exactly once under a concurrent
//    handshake-complete + timeout race (no CONTINUATION MISUSE trap).
//  - L-11: a failed DTLS open issues a compensating action=stop so the
//    entertainment configuration is not left activated on the bridge.
//  - M-06: deactivateStuckEntertainmentSessions excludes the app's own
//    active (registered) session and still stops a genuinely stale one.
//
// M-10 (send-failure reconnect) requires a live DTLS socket and is covered
// by the on-device checkpoint; the reconnect scheduling is bounded by code
// inspection (max 3 attempts, cancelled in stopSession).
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Entertainment / DTLS".

import XCTest
@testable import HueHome

// MARK: - Spy REST client (records entertainment_configuration PUTs)

private final class EntertainmentSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [(configID: String, action: String)] = []
    var actions: [(configID: String, action: String)] {
        lock.lock(); defer { lock.unlock() }
        return _actions
    }

    /// entertainment_configuration list returned by GET.
    var stubConfigsJSON: String = #"{"data": []}"#

    override func get(path: String, ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration") {
            return Data(stubConfigsJSON.utf8)
        }
        return Data("{}".utf8)
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration/"),
           let action = body["action"] as? String,
           let configID = path.split(separator: "/").last.map(String.init) {
            lock.lock()
            _actions.append((configID, action))
            lock.unlock()
        }
        return Data("{}".utf8)
    }
}

// MARK: - Tests

final class EntertainmentRobustnessTests: XCTestCase {

    // ──────────────────────────────────────────────
    // MARK: - M-09: continuation resumes exactly once
    // ──────────────────────────────────────────────

    func testContinuationGateResumesExactlyOnceUnderConcurrency() async {
        for _ in 0..<50 {
            let gate = ContinuationGate()
            let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask { gate.tryResume() }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            XCTAssertEqual(winners, 1,
                "exactly ONE racer may resume the continuation (M-09 double-resume trap)")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - L-11: failed open sends a compensating action=stop
    // ──────────────────────────────────────────────

    func testFailedDTLSOpenIssuesCompensatingStop() async {
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        // Invalid (non-hex) client key → openDTLSConnection throws before any
        // network I/O, exercising the failed-open path deterministically.
        let client = HueEntertainmentClient(bridgeIP: "192.0.2.1",
                                            username: "user",
                                            clientKeyHex: "ZZ-not-hex",
                                            restClient: spy)

        do {
            try await client.startSession(configID: "cfg-fail")
            XCTFail("startSession must throw when the DTLS open fails")
        } catch {
            // expected
        }

        let actions = spy.actions
        XCTAssertEqual(actions.map(\.action), ["start", "stop"],
            "a failed open must roll back with action=stop (L-11)")
        XCTAssertEqual(Set(actions.map(\.configID)), ["cfg-fail"])
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-fail"),
            "a failed session must not stay registered as app-owned")
    }

    // ──────────────────────────────────────────────
    // MARK: - M-06: app-owned sessions excluded from stuck cleanup
    // ──────────────────────────────────────────────

    @MainActor
    func testStuckCleanupSkipsAppOwnedSessionAndStopsStaleOne() async {
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        spy.stubConfigsJSON = """
        {"data": [
            {"id": "cfg-ours",  "status": "active"},
            {"id": "cfg-stale", "status": "active"},
            {"id": "cfg-idle",  "status": "inactive"}
        ]}
        """
        let orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-1": spy])

        HueEntertainmentClient.registerActiveSession(configID: "cfg-ours")
        defer { HueEntertainmentClient.unregisterActiveSession(configID: "cfg-ours") }

        await orchestrator.deactivateStuckEntertainmentSessions()

        let stopped = spy.actions.filter { $0.action == "stop" }.map(\.configID)
        XCTAssertEqual(stopped, ["cfg-stale"],
            "cleanup must stop the stale session and NEVER the app's own active one (M-06)")
    }

    func testSessionRegistryRegisterUnregister() {
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
        HueEntertainmentClient.registerActiveSession(configID: "cfg-x")
        XCTAssertTrue(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
        HueEntertainmentClient.unregisterActiveSession(configID: "cfg-x")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
    }
}
