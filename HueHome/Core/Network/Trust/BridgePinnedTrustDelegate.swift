// BridgePinnedTrustDelegate.swift
// ChromaGlow — Bridge TLS trust (audit H-01/H-02/M-01/H-06, Decision D-016)
//
// The ONE URLSession trust delegate for every bridge surface: app REST
// (v1 + v2), SSE, widget timeline + widget intents, Siri intents, and watch.
// Replaces HueCertTrustDelegate / BridgeCertTrustDelegate / TrustAll /
// TrustDelegate, all of which returned `.useCredential` unconditionally.
//
// BridgePairingTrustDelegate is the TOFU-capture variant used ONLY for the
// user-initiated pairing window and the one-time upgrade pin migration; it
// additionally enforces leaf continuity within its session (Android D-014).
//
// Scripts/hardening_guards.sh Guard 3 bans `.useCredential` outside this
// folder, so a trust-all delegate cannot silently return.

import Foundation
import Security
import OSLog

// MARK: - Data-plane delegate (pinned, fail-closed)

final class BridgePinnedTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    /// One instance for all clients — pins are read per-challenge, so a pin
    /// added at pairing time is visible to already-created sessions.
    static let shared = BridgePinnedTrustDelegate()

    private let log = Logger(subsystem: "com.lightshade.app", category: "BridgeTrust")
    private let pinProvider: @Sendable () -> [BridgePin]

    init(pinProvider: @escaping @Sendable () -> [BridgePin] = { BridgePinStore.shared.loadPins() }) {
        self.pinProvider = pinProvider
    }

    /// The single decision point — exposed for direct unit testing.
    /// Never returns `.useCredential` unless BridgeTrust.verdict accepted,
    /// which itself requires a successful SecTrustEvaluateWithError.
    func disposition(for serverTrust: SecTrust?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let serverTrust else { return (.cancelAuthenticationChallenge, nil) }
        switch BridgeTrust.verdict(trust: serverTrust, pins: pinProvider()) {
        case .acceptedPinned:
            return (.useCredential, URLCredential(trust: serverTrust))
        case .acceptedCAValidatedRotation(let bridgeID, let newPin):
            // CA-attested cert rotation: re-pin so the next check is exact.
            BridgePinStore.shared.save(pin: newPin)
            log.info("BridgeTrust: CA-validated cert rotation re-pinned for \(bridgeID)")
            return (.useCredential, URLCredential(trust: serverTrust))
        case .rejected(let reason):
            log.error("BridgeTrust: rejected bridge TLS challenge (\(reason.rawValue, privacy: .public))")
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let (disposition, credential) = disposition(for: challenge.protectionSpace.serverTrust)
        completionHandler(disposition, credential)
    }

    // Session-level (TLS handshake at session open time).
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    // Task-level — iOS 15+ routes data/bytes task challenges here.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }
}

// MARK: - Pairing / TOFU delegate (capture + same-leaf continuity)

final class BridgePairingTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    private let log = Logger(subsystem: "com.lightshade.app", category: "BridgeTrust")
    private let lock = NSLock()
    private var _capture: PairingLeafCapture?

    /// The leaf identity observed on this session's first handshake.
    var capture: PairingLeafCapture? {
        lock.lock()
        defer { lock.unlock() }
        return _capture
    }

    /// Exposed for direct unit testing (same contract as the pinned delegate).
    func disposition(for serverTrust: SecTrust?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let serverTrust,
              let candidate = BridgeTrust.pairingCapture(trust: serverTrust) else {
            log.error("BridgeTrust: pairing handshake rejected (invalid chain or CN)")
            return (.cancelAuthenticationChallenge, nil)
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = _capture {
            // Identity continuity within one pairing session (Android D-014):
            // every handshake must present the exact same leaf.
            guard existing.certSHA256 == candidate.certSHA256 else {
                log.error("BridgeTrust: pairing leaf changed mid-session — rejected")
                return (.cancelAuthenticationChallenge, nil)
            }
        } else {
            _capture = candidate
        }
        return (.useCredential, URLCredential(trust: serverTrust))
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let (disposition, credential) = disposition(for: challenge.protectionSpace.serverTrust)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }
}

// MARK: - Upgrade pin migration (bridges paired before D-016)

enum BridgePinAcquirer {

    private static let log = Logger(subsystem: "com.lightshade.app", category: "BridgeTrust")

    /// Failed acquisitions are not retried for this long, so the periodic
    /// loadAll refresh doesn't hammer an offline bridge.
    private static let retryInterval: TimeInterval = 60
    private static let attemptLock = NSLock()
    nonisolated(unsafe) private static var lastAttemptByHost: [String: Date] = [:]

    /// One-time TOFU pin acquisition for every host that has no stored pin.
    /// No-op once every host is pinned. Runs before the first data-plane
    /// fetch so existing users are migrated instead of failing closed.
    static func ensurePins(hosts: [String]) async {
        // Unit-test processes must never perform live pin acquisition.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        for host in Set(hosts) where !BridgePinStore.shared.hasPin(forHost: host) {
            let now = Date()
            let shouldAttempt: Bool = {
                attemptLock.lock()
                defer { attemptLock.unlock() }
                if let last = lastAttemptByHost[host], now.timeIntervalSince(last) < retryInterval {
                    return false
                }
                lastAttemptByHost[host] = now
                return true
            }()
            guard shouldAttempt else { continue }
            await acquirePin(host: host)
        }
    }

    /// Fetch /api/0/config (unauthenticated) over a TOFU-capture session,
    /// require config.bridgeid == leaf CN, then pin. A key that differs from
    /// an existing pin for the same bridgeid is accepted only when the leaf
    /// chain is CA-validated (rotation) — otherwise this fails closed.
    @discardableResult
    static func acquirePin(host: String) async -> Bool {
        let delegate = BridgePairingTrustDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        guard let url = URL(string: "https://\(host)/api/0/config") else { return false }
        do {
            let (data, _) = try await session.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawID = object["bridgeid"] as? String,
                  let configBridgeID = BridgeTrust.canonicalBridgeID(from: rawID),
                  let capture = delegate.capture,
                  capture.bridgeID == configBridgeID else {
                log.error("BridgeTrust: pin migration failed — config/CN identity mismatch or malformed config")
                return false
            }
            if let existing = BridgePinStore.shared.pin(forBridgeID: capture.bridgeID),
               existing.publicKeySHA256 != capture.publicKeySHA256,
               !capture.caValidated {
                // A different key claiming an already-pinned bridgeid, without a
                // CA-validated chain, is exactly the MITM this feature exists
                // to stop. Never let the migration path overwrite a pin.
                log.error("BridgeTrust: pin migration refused — key mismatch for pinned bridgeid without CA validation")
                return false
            }
            BridgePinStore.shared.save(pin: capture.pin(host: host))
            log.info("BridgeTrust: pinned bridge identity for \(capture.bridgeID)")
            return true
        } catch {
            log.error("BridgeTrust: pin migration fetch failed — \(error.localizedDescription)")
            return false
        }
    }
}
