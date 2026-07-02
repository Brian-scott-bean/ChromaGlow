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
// NOTE: the two delegates deliberately do NOT share a base class. The widget
// and watch targets were created with default-MainActor isolation while the
// app target was not, so cross-target subclass overrides of a shared delegate
// hit actor-isolation mismatches. The ~30 duplicated plumbing lines are the
// cheaper trade.
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
            // Persisted off the TLS callback thread — the handshake should not
            // wait on Keychain/UserDefaults I/O.
            Task.detached(priority: .utility) {
                BridgePinStore.shared.save(pin: newPin)
            }
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

// MARK: - Pin acquisition (pairing persist gate + upgrade migration)

enum BridgePinAcquirer {

    private static let log = Logger(subsystem: "com.lightshade.app", category: "BridgeTrust")

    /// Failed acquisitions are not retried for this long, so the periodic
    /// loadAll refresh doesn't hammer an offline bridge, while a pull-to-
    /// refresh after a transient failure still recovers quickly.
    private static let retryInterval: TimeInterval = 15
    private static let attemptLock = NSLock()
    nonisolated(unsafe) private static var lastAttemptByHost: [String: Date] = [:]

    /// The single persist gate shared by pairing and migration:
    /// - the config-reported bridgeid must equal the captured leaf CN;
    /// - an existing pin is NEVER overwritten by a different key unless the
    ///   presented chain is CA-attested (bundled Signify roots); and
    /// - in the `unattended` context (the upgrade migration, which runs with no
    ///   user present), a *first* pin is accepted ONLY for a CA-attested leaf.
    ///
    /// The last rule closes a silent first-launch MITM: without it, an on-path
    /// LAN attacker present at the first post-upgrade `loadAll` could answer the
    /// unauthenticated `/api/0/config` probe with a self-signed cert + matching
    /// bridgeid and get a ghost pin persisted, then capture the app key. A
    /// self-signed bridge (`caValidated == false`) can still be pinned, but only
    /// through interactive pairing (`unattended: false`), which is gated by the
    /// physical link-button press — presence the silent path cannot assume.
    static func validateAndPersist(
        capture: PairingLeafCapture,
        configBridgeID: String,
        host: String,
        unattended: Bool
    ) -> Bool {
        guard capture.bridgeID == configBridgeID else {
            log.error("BridgeTrust: identity mismatch — leaf CN != /api/0/config bridgeid")
            return false
        }
        let existing = BridgePinStore.shared.pin(forBridgeID: capture.bridgeID)
        if let existing,
           existing.publicKeySHA256 != capture.publicKeySHA256,
           !capture.caValidated {
            // A different key claiming an already-pinned bridgeid, without a
            // CA-validated chain, is exactly the MITM this feature exists to
            // stop. Recovery for a legitimately changed certificate: forget
            // the bridge (which drops its pin), then pair again.
            log.error("BridgeTrust: refused to overwrite pin — key changed without CA validation")
            return false
        }
        if existing == nil, unattended, !capture.caValidated {
            // No prior pin + no CA attestation + no user present → do not TOFU.
            // The bridge stays fail-closed until the user re-pairs by pressing
            // the physical link button.
            log.error("BridgeTrust: refused silent first pin for a self-signed bridge — re-pair required")
            return false
        }
        BridgePinStore.shared.save(pin: capture.pin(host: host))
        log.info("BridgeTrust: pinned bridge identity")
        return true
    }

    /// One-time TOFU pin acquisition for every host that has no stored pin.
    /// No-op once every host is pinned. Runs before the first data-plane
    /// fetch so existing users are migrated instead of failing closed.
    /// Hosts are probed CONCURRENTLY so one offline bridge cannot stall the
    /// others (or the fetches behind this call) beyond a single timeout.
    static func ensurePins(hosts: [String]) async {
        // Unit-test processes must never perform live pin acquisition.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let now = Date()
        let pending = Set(hosts).filter { host in
            guard !BridgePinStore.shared.hasPin(forHost: host) else { return false }
            attemptLock.lock()
            defer { attemptLock.unlock() }
            if let last = lastAttemptByHost[host], now.timeIntervalSince(last) < retryInterval {
                return false
            }
            lastAttemptByHost[host] = now
            return true
        }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for host in pending {
                group.addTask { await acquirePin(host: host) }
            }
        }
    }

    /// Fetch /api/0/config (unauthenticated) over a TOFU-capture session,
    /// then run the shared validateAndPersist gate.
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
            guard let configBridgeID = BridgeTrust.bridgeID(fromConfigResponse: data),
                  let capture = delegate.capture else {
                log.error("BridgeTrust: pin migration failed — no capture or malformed config")
                return false
            }
            return validateAndPersist(
                capture: capture, configBridgeID: configBridgeID, host: host, unattended: true
            )
        } catch {
            log.error("BridgeTrust: pin migration fetch failed — \(error.localizedDescription)")
            return false
        }
    }
}
