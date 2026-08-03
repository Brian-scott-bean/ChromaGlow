// HueEntertainmentClient.swift
// CastChroma — Hue Entertainment API (Streaming)
//
// DTLS-encrypted UDP streaming client for near-real-time light control.
// Uses Apple Network.framework with PSK cipher for Hue Bridge.
//
// Protocol: UDP port 2100, DTLS 1.2, TLS_PSK_WITH_AES_128_GCM_SHA256
// PSK identity = bridge username (API token)
// PSK key      = bridge clientkey (32-char hex → 16 bytes)
//
// Packet format (V2):
//   Header (16 bytes):
//     "HueStream" (9) + API version 0x02 0x00 (2) + sequence (1)
//     + reserved 0x00 0x00 (2) + color space 0x01=XYB (1) + reserved 0x00 (1)
//   Entertainment config ID as ASCII UUID (36 bytes)
//   Per-channel (7 bytes each):
//     channel_id (1) + X (2 big-endian) + Y (2 big-endian) + brightness (2 big-endian)

import Foundation
import Network
import os

// MARK: - Entertainment Config Model

struct EntertainmentConfig: Identifiable, Sendable {
    let id: String              // UUID of the entertainment_configuration resource
    let name: String
    let channels: [EntertainmentChannel]
}

struct EntertainmentChannel: Identifiable, Sendable {
    let id: Int                 // channel_id (0-based)
    let lightServiceIDs: [String]  // references to light resources in this channel
    let position: (x: Double, y: Double, z: Double)

    var identifier: Int { id }  // Identifiable conformance workaround
}

// MARK: - Streaming State

enum EntertainmentStreamState: Sendable {
    case disconnected
    case connecting
    case streaming
    case error(String)
}

// MARK: - ContinuationGate

/// Thread-safe resume-exactly-once gate for checked continuations (M-09).
/// The DTLS handshake completion and its timeout race on different queues;
/// both observing `resumed == false` double-resumed the continuation —
/// a SWIFT TASK CONTINUATION MISUSE hard trap.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns true exactly once — the caller that wins may resume.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }
}

// MARK: - Entertainment session ownership (packet 7)

/// Non-secret evidence that ChromaGlow started a specific Entertainment
/// session. Deliberately carries no token, client key, username, IP, or light
/// data — it exists only so a later launch can tell "our session, orphaned by
/// a force-quit" apart from "somebody else's show".
struct EntertainmentOwnershipRecord: Codable, Equatable, Sendable {
    let bridgeID: String
    let configID: String
    let startedAt: Date
}

/// The exact identity of an Entertainment session. Keyed by BRIDGE plus
/// configuration: a configuration UUID alone is not ownership, because the
/// same UUID observed on bridge B says nothing about the session we started
/// on bridge A.
struct EntertainmentSessionKey: Hashable, Sendable {
    let bridgeID: String
    let configID: String
}

/// The outcome of releasing one current-process reference.
///
/// Two live ChromaGlow clients can legitimately hold the same bridge +
/// configuration (a Studio card and a composition). Only the LAST of them may
/// send `action=stop`; an earlier release that stopped the session would kill
/// a stream its owner still believes is running.
struct EntertainmentProcessRelease: Equatable, Sendable {
    /// True when this release dropped the final current-process reference —
    /// the only case permitted to stop the session on the bridge.
    let wasFinalOwner: Bool
    /// References still held after this release. `> 0` means another live
    /// ChromaGlow client is streaming this exact bridge + configuration.
    let remaining: Int
}

/// Two-layer ownership for Entertainment sessions.
///
/// A. **Current process** — reference-counted, keyed by exact bridge +
///    configuration. Protects a live stream from this app's own cleanup.
/// B. **Persisted** — non-secret evidence that survives termination, so a
///    later launch can clean up a session this app left active without ever
///    touching a session it did not start.
///
/// `nonisolated` + `NSLock` on purpose: the `HueEntertainmentClient` actor and
/// the `@MainActor` cleanup pass both need it without an isolation hop.
final class EntertainmentSessionOwnership: @unchecked Sendable {

    static let shared = EntertainmentSessionOwnership()

    /// Bounded so a pathological run cannot grow the blob without limit; the
    /// oldest record is dropped first.
    private static let maxPersistedRecords = 32
    private static let defaultsKey = "castchroma.entertainmentOwnership.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults

    private var processRefCounts: [EntertainmentSessionKey: Int] = [:]
    private var persisted: [EntertainmentOwnershipRecord] = []
    /// Exclusive destructive rights held by an in-flight cleanup stop.
    private var cleanupClaims: [EntertainmentSessionKey: UUID] = [:]

    /// `defaults` is injectable for tests only.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([EntertainmentOwnershipRecord].self, from: data) {
            persisted = decoded
        }
    }

    // MARK: A — current-process ownership

    /// Whether a start may proceed to `action=start`.
    enum ProcessRegistration: Equatable {
        case registered
        /// Cleanup holds a destructive claim on this exact bridge +
        /// configuration. Starting now would race its `action=stop`.
        case blockedByCleanup
    }

    @discardableResult
    func registerProcess(bridgeID: String, configID: String) -> ProcessRegistration {
        let key = EntertainmentSessionKey(bridgeID: bridgeID, configID: configID)
        lock.lock()
        defer { lock.unlock() }
        // A claim is an exclusive right to destroy this session. Registering
        // underneath one would produce an owner that cleanup has already
        // decided to stop — the two would then race, and the loser is a live
        // show going dark for no reason anyone can see.
        guard cleanupClaims[key] == nil else { return .blockedByCleanup }
        processRefCounts[key, default: 0] += 1
        return .registered
    }

    /// Drops one reference and reports whether the caller was the final owner.
    ///
    /// Releasing something never registered reports `wasFinalOwner: false` —
    /// an unbalanced release must never authorize a stop.
    @discardableResult
    func releaseProcess(bridgeID: String, configID: String) -> EntertainmentProcessRelease {
        let key = EntertainmentSessionKey(bridgeID: bridgeID, configID: configID)
        lock.lock()
        defer { lock.unlock() }
        guard let count = processRefCounts[key] else {
            return EntertainmentProcessRelease(wasFinalOwner: false, remaining: 0)
        }
        if count <= 1 {
            processRefCounts.removeValue(forKey: key)
            return EntertainmentProcessRelease(wasFinalOwner: true, remaining: 0)
        }
        processRefCounts[key] = count - 1
        return EntertainmentProcessRelease(wasFinalOwner: false, remaining: count - 1)
    }

    /// True when THIS app process is currently streaming that exact bridge +
    /// configuration.
    func isProcessOwned(bridgeID: String, configID: String) -> Bool {
        let key = EntertainmentSessionKey(bridgeID: bridgeID, configID: configID)
        lock.lock()
        defer { lock.unlock() }
        return processRefCounts[key] != nil
    }

    func processOwnedConfigIDs(onBridge bridgeID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(processRefCounts.keys.filter { $0.bridgeID == bridgeID }.map(\.configID))
    }

    // MARK: A' — the stale-cleanup claim
    //
    // Asking "is it still recorded?" and "does it have an owner?" as two
    // separate questions, then awaiting a network stop, is not an
    // authorization — it is two facts that were true at some point, followed
    // by a suspension during which either can stop being true. The claim makes
    // the decision and the exclusive right to act on it one indivisible step.

    /// An exclusive right to stop one exact bridge + configuration.
    struct StaleCleanupClaim: Equatable, Sendable {
        let bridgeID: String
        let configID: String
        let token: UUID
    }

    /// Atomically verify that this session is genuinely stale ChromaGlow state
    /// and take the exclusive right to stop it. Returns nil when it is not
    /// ours to destroy — no record, a live owner, or another claim in flight.
    ///
    /// The lock is held for the decision only; the caller awaits the network
    /// afterwards, protected by the claim rather than by the lock.
    func beginStaleCleanup(bridgeID: String, configID: String) -> StaleCleanupClaim? {
        let key = EntertainmentSessionKey(bridgeID: bridgeID, configID: configID)
        lock.lock()
        defer { lock.unlock() }
        guard persisted.contains(where: { $0.bridgeID == bridgeID && $0.configID == configID }),
              processRefCounts[key] == nil,
              cleanupClaims[key] == nil
        else { return nil }

        let claim = StaleCleanupClaim(bridgeID: bridgeID, configID: configID, token: UUID())
        cleanupClaims[key] = claim.token
        return claim
    }

    /// Release the claim, whether the stop succeeded or failed. Releasing a
    /// superseded claim is a no-op.
    func endStaleCleanup(_ claim: StaleCleanupClaim) {
        let key = EntertainmentSessionKey(bridgeID: claim.bridgeID, configID: claim.configID)
        lock.lock()
        defer { lock.unlock() }
        guard cleanupClaims[key] == claim.token else { return }
        cleanupClaims.removeValue(forKey: key)
    }

    /// TEST SEAM: is this exact key claimed right now?
    func hasCleanupClaim(bridgeID: String, configID: String) -> Bool {
        let key = EntertainmentSessionKey(bridgeID: bridgeID, configID: configID)
        lock.lock()
        defer { lock.unlock() }
        return cleanupClaims[key] != nil
    }

    // MARK: B — persisted ownership evidence

    func recordPersisted(bridgeID: String, configID: String, startedAt: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        persisted.removeAll { $0.bridgeID == bridgeID && $0.configID == configID }
        persisted.append(EntertainmentOwnershipRecord(bridgeID: bridgeID,
                                                      configID: configID,
                                                      startedAt: startedAt))
        if persisted.count > Self.maxPersistedRecords {
            persisted.removeFirst(persisted.count - Self.maxPersistedRecords)
        }
        writeLocked()
    }

    func forgetPersisted(bridgeID: String, configID: String) {
        lock.lock()
        defer { lock.unlock() }
        let before = persisted.count
        persisted.removeAll { $0.bridgeID == bridgeID && $0.configID == configID }
        guard persisted.count != before else { return }
        writeLocked()
    }

    func isPersisted(bridgeID: String, configID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return persisted.contains { $0.bridgeID == bridgeID && $0.configID == configID }
    }

    func persistedConfigIDs(onBridge bridgeID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(persisted.filter { $0.bridgeID == bridgeID }.map(\.configID))
    }

    /// TEST SEAM: drop every record so an isolated suite starts empty.
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        processRefCounts = [:]
        persisted = []
        cleanupClaims = [:]
        writeLocked()
    }

    private func writeLocked() {
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - HueEntertainmentClient

/// Manages a DTLS streaming session to a Hue Bridge.
/// Lifecycle: configure() → startSession() → send() in loop → stopSession()
actor HueEntertainmentClient {

    // MARK: State
    private(set) var state: EntertainmentStreamState = .disconnected

    // MARK: Connection
    private var connection: NWConnection?
    private var sequenceNumber: UInt8 = 0

    // MARK: Config
    private let bridgeID: String         // stable bridge identity (never the IP)
    private let bridgeIP: String
    private let username: String         // PSK identity
    private let clientKeyHex: String     // 32-char hex string
    private var configID: String = ""    // entertainment configuration UUID

    // MARK: REST client for start/stop
    private let restClient: HueAPIClient

    // MARK: Reconnect (M-10)
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3

    /// True once the bounded reconnect has been exhausted and the session
    /// torn down. Owning render loops poll this to fail over to REST instead
    /// of streaming into a dead socket. Reset by the next startSession.
    private(set) var isTerminallyFailed = false

    private let log = Logger(subsystem: "com.lightshade.app", category: "Entertainment")

    // MARK: - Session ownership (M-06, rebuilt in packet 7)
    //
    // Ownership moved out of a process-global `[configID: Int]` and into
    // `EntertainmentSessionOwnership`, for two reasons the old registry could
    // not address:
    //
    //  1. A configuration UUID alone is not an identity. The same UUID seen on
    //     another bridge authorized stopping a session we never started.
    //  2. A process-only refcount dies with the process. After an unclean
    //     termination the bridge still reports OUR configuration active, with
    //     nothing to distinguish it from a third party's show — so cleanup
    //     either evicted strangers or leaked our own sessions forever.
    private let ownership: EntertainmentSessionOwnership

    // MARK: Init

    init(bridgeID: String,
         bridgeIP: String,
         username: String,
         clientKeyHex: String,
         restClient: HueAPIClient,
         ownership: EntertainmentSessionOwnership = .shared) {
        self.bridgeID = bridgeID
        self.bridgeIP = bridgeIP
        self.username = username
        self.clientKeyHex = clientKeyHex
        self.restClient = restClient
        self.ownership = ownership
    }

    // MARK: - Session Lifecycle

    /// Start an entertainment streaming session.
    /// 1. PUT /entertainment_configuration/{id} action=start via REST
    /// 2. Open DTLS connection to bridge:2100
    func startSession(configID: String) async throws {
        self.configID = configID
        isTerminallyFailed = false
        state = .connecting
        log.info("Starting entertainment session for config \(configID)")

        // Register BEFORE the REST activate: the bridge reports the config
        // "active" the moment action=start lands, and a concurrent loadAll
        // cleanup pass must already see it as app-owned — otherwise it can
        // stop our own session during the (up to 10s) DTLS handshake window.
        //
        // Both layers are installed here. The persisted record is what lets a
        // LATER LAUNCH recognise this session as ours if this process dies
        // before it can stop cleanly.
        //
        // Cleanup may already hold the exclusive right to stop this exact
        // session. Registering underneath that claim would create an owner
        // whose `action=stop` is already in flight, so refuse rather than race
        // it. The window is one PUT wide, and the caller's honest response is
        // its normal room-mode fallback.
        guard ownership.registerProcess(bridgeID: bridgeID, configID: configID) == .registered else {
            self.configID = ""
            state = .error("Entertainment session is being cleaned up")
            log.warning("Refusing to start \(configID) — stale cleanup holds a claim on it")
            throw EntertainmentError.cleanupInProgress
        }
        ownership.recordPersisted(bridgeID: bridgeID, configID: configID)

        // Step 1: Activate the entertainment config via REST
        do {
            let (ip, token) = try restClient.credentials()
            let body: [String: Any] = ["action": "start"]
            _ = try await restClient.put(
                path: "/clip/v2/resource/entertainment_configuration/\(configID)",
                body: body, ip: ip, token: token
            )
            log.info("Entertainment config activated via REST")
        } catch {
            // The activation did not land. Drop OUR reference — but only the
            // final owner may retract the shared evidence: when another live
            // client still holds this exact bridge + configuration, forgetting
            // the persisted record would strip the protection its session is
            // relying on.
            let release = ownership.releaseProcess(bridgeID: bridgeID, configID: configID)
            if release.wasFinalOwner {
                // Classify by TYPE, never by error text. An HTTP/bridge error
                // means the bridge answered and did not activate — definitively
                // nothing to clean up. Anything else (transport failure) leaves
                // the outcome unknown, so the record is retained and a later
                // launch can retry.
                if Self.isDefinitiveActivationFailure(error) {
                    ownership.forgetPersisted(bridgeID: bridgeID, configID: configID)
                } else {
                    log.warning("Entertainment activate outcome unknown — keeping ownership record for later cleanup")
                }
            }
            self.configID = ""
            state = .error("Failed to activate: \(error.localizedDescription)")
            log.error("REST activate failed: \(error.localizedDescription)")
            throw error
        }

        // Step 2: Open DTLS connection.
        // L-11: a failed open used to leave the configuration activated on
        // the bridge with no rollback — send a compensating action=stop.
        do {
            try await openDTLSConnection()
        } catch {
            await sendBestEffortStop()
            state = .error("DTLS open failed: \(error.localizedDescription)")
            throw error
        }

        reconnectAttempts = 0
    }

    /// Did this session actually reach a usable streaming state?
    ///
    /// `startSession` returning is not proof on its own — it means the REST
    /// activate was accepted and the DTLS handshake reported ready, which is
    /// two of the three things that have to be true. This is the third: the
    /// actor committed `.streaming` and nothing has terminally failed it since.
    ///
    /// Creating a client is not streaming, and the hardware pass is what made
    /// the difference matter: ChromaGlow reported a successful takeover while
    /// Hue Sync was still visibly in control of the lights.
    func hasStartedSession() -> Bool {
        guard case .streaming = state else { return false }
        return !isTerminallyFailed
    }

    /// Stop the streaming session.
    /// 1. Close DTLS connection
    /// 2. PUT /entertainment_configuration/{id} action=stop via REST
    func stopSession() async {
        log.info("Stopping entertainment session")

        // Cancel any pending reconnect (M-10)
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        // Close DTLS
        connection?.cancel()
        connection = nil

        await sendBestEffortStop()

        state = .disconnected
        sequenceNumber = 0
    }

    /// Shared session teardown: release this client's ownership reference and,
    /// when it was the last one, best-effort `action=stop` on the bridge. Used
    /// by stopSession, the failed-open rollback (L-11), and reconnect
    /// abandonment (M-10) so the teardown protocol cannot drift.
    ///
    /// Only the FINAL current-process owner sends the stop. Two ChromaGlow
    /// clients can legitimately stream the same bridge + configuration (a
    /// Studio card and a composition); an earlier release that stopped the
    /// session would black out a stream whose owner still believes it is
    /// running — and, for a failed DTLS open, would do it as "rollback".
    private func sendBestEffortStop() async {
        guard !configID.isEmpty else { return }
        let stoppingConfigID = configID
        let release = ownership.releaseProcess(bridgeID: bridgeID, configID: stoppingConfigID)
        configID = ""

        guard release.wasFinalOwner else {
            log.info("Entertainment session \(stoppingConfigID) still held by \(release.remaining) other client(s) — not stopping")
            return
        }

        do {
            let (ip, token) = try restClient.credentials()
            let body: [String: Any] = ["action": "stop"]
            _ = try await restClient.put(
                path: "/clip/v2/resource/entertainment_configuration/\(stoppingConfigID)",
                body: body, ip: ip, token: token
            )
            log.info("Entertainment action=stop sent")
            // The bridge confirmed the stop, so the evidence has done its job.
            // A FAILED stop deliberately keeps the record: the configuration
            // may still be active, and a later launch must be able to retry.
            ownership.forgetPersisted(bridgeID: bridgeID, configID: stoppingConfigID)
        } catch {
            log.warning("action=stop failed (bridge inactivity timeout will recover): \(error.localizedDescription)")
        }
    }

    /// True when the bridge answered and refused to activate — a definitive
    /// "nothing was started". Transport-level failures leave the outcome
    /// genuinely unknown and must NOT be treated as definitive.
    ///
    /// Typed classification on purpose: inferring this from an error's English
    /// description is how ownership decisions start depending on wording.
    private static func isDefinitiveActivationFailure(_ error: Error) -> Bool {
        switch error {
        case HueAPIError.httpError, HueAPIError.bridgeError, HueAPIError.missingCredentials,
             HueAPIError.badURL:
            return true
        default:
            return false
        }
    }

    // MARK: - Send Light Data

    /// Send a frame of light data to all channels.
    /// Call this at 25-50fps for smooth lighting.
    ///
    /// - Parameter channels: Array of (channelID, x, y, brightness) tuples.
    ///   x, y: CIE 1931 color coordinates (0.0–1.0)
    ///   brightness: 0.0–1.0
    func send(channels: [(id: UInt8, x: Double, y: Double, brightness: Double)]) {
        guard case .streaming = state, let conn = connection else { return }

        let packet = buildPacket(channels: channels)
        conn.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { await self?.handleSendError(error) }
            }
        })
    }

    /// Convenience: send uniform color + brightness to all channels.
    func sendUniform(channelIDs: [UInt8], x: Double, y: Double, brightness: Double) {
        let channels = channelIDs.map { (id: $0, x: x, y: y, brightness: brightness) }
        send(channels: channels)
    }

    // MARK: - DTLS Connection

    /// Hue entertainment clientkeys are always 32 hex chars — a 16-byte PSK for
    /// TLS_PSK_WITH_AES_128_GCM_SHA256. Any other length can only end as an
    /// opaque DTLS handshake timeout 10 s later, so refuse it up front (L-12).
    static func decodePSK(_ hex: String) -> Data? {
        guard let data = Data(hexString: hex), data.count == 16 else { return nil }
        return data
    }

    private func openDTLSConnection() async throws {
        // Convert hex client key to binary (length-validated — audit L-12)
        guard let pskData = Self.decodePSK(clientKeyHex) else {
            state = .error("Invalid client key format")
            throw EntertainmentError.invalidClientKey
        }

        guard let identityData = username.data(using: .utf8) else {
            state = .error("Invalid username encoding")
            throw EntertainmentError.invalidUsername
        }

        // Configure DTLS with PSK
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_add_pre_shared_key(
            tlsOptions.securityProtocolOptions,
            pskData.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            identityData.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )

        // Set minimum TLS version to DTLS 1.2
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .DTLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .DTLSv12
        )

        // Append required cipher suite
        sec_protocol_options_append_tls_ciphersuite(
            tlsOptions.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: 0x00A8)!  // TLS_PSK_WITH_AES_128_GCM_SHA256
        )

        let params = NWParameters(dtls: tlsOptions, udp: .init())

        let host = NWEndpoint.Host(bridgeIP)
        guard let port = NWEndpoint.Port(rawValue: 2100) else {
            state = .error("Invalid port")
            throw EntertainmentError.connectionFailed
        }

        let conn = NWConnection(host: host, port: port, using: params)

        // M-09: the state handler (userInteractive queue) and the timeout
        // (default global queue) race — the gate makes resume atomic so a
        // simultaneous handshake-complete + timeout can never double-resume
        // the continuation (SWIFT TASK CONTINUATION MISUSE trap).
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()

            conn.stateUpdateHandler = { [weak self] newState in
                guard let self, !gate.isResumed else { return }
                switch newState {
                case .ready:
                    guard gate.tryResume() else { return }
                    // The resume happens INSIDE the same task that commits the
                    // streaming state, not beside it. Detached, the two raced:
                    // `startSession` could return while `state` was still
                    // `.connecting`, so "the call returned" was not evidence
                    // that a session existed — and every caller was reading it
                    // as exactly that before publishing ownership.
                    Task {
                        await self.setStreaming(conn)
                        continuation.resume()
                    }

                case .failed(let error):
                    guard gate.tryResume() else { return }
                    Task { await self.setError("DTLS failed: \(error.localizedDescription)") }
                    continuation.resume(throwing: EntertainmentError.dtlsFailed(error))

                case .waiting(let error):
                    // Waiting usually means handshake in progress — log but don't fail yet
                    Task {
                        await self.logMessage("DTLS waiting: \(error.localizedDescription)")
                    }

                case .cancelled:
                    guard gate.tryResume() else { return }
                    continuation.resume(throwing: EntertainmentError.connectionFailed)

                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInteractive))

            // Timeout after 10 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard gate.tryResume() else { return }
                conn.cancel()
                continuation.resume(throwing: EntertainmentError.timeout)
            }
        }
    }

    // Actor-isolated state setters for use from callbacks
    private func setStreaming(_ conn: NWConnection) {
        self.connection = conn
        self.state = .streaming
        log.info("DTLS connected — streaming active")
    }

    private func setError(_ msg: String) {
        self.state = .error(msg)
        log.error("\(msg)")
    }

    private func logMessage(_ msg: String) {
        log.info("\(msg)")
    }

    private func handleSendError(_ error: NWError) {
        log.error("Send error: \(error.localizedDescription)")
        // M-10: the old path only flipped state — every later frame silently
        // no-oped and the lights froze on their last frame for the rest of
        // the session. Cancel the dead connection and drive a bounded
        // reconnect; frames resume automatically once streaming again.
        state = .error("Send failed")
        connection?.cancel()
        connection = nil
        scheduleReconnect()
    }

    // MARK: - Reconnect (M-10)

    private func scheduleReconnect() {
        guard reconnectTask == nil, !configID.isEmpty else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            // Abandon: the session is dead. Tear it down fully — unregister
            // from the app-owned registry and best-effort stop the config —
            // otherwise the stuck-session cleanup would skip this dead-but-
            // "owned" config forever and the bridge would stay locked.
            log.error("Entertainment reconnect abandoned after \(Self.maxReconnectAttempts) attempts — tearing session down")
            Task { [weak self] in await self?.noteTerminalFailure() }
            return
        }
        reconnectAttempts += 1
        let backoffMs = 300 * reconnectAttempts
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(backoffMs))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    /// Marks the session terminally failed and tears it down (unregister +
    /// best-effort action=stop). Internal — not private — so the robustness
    /// tests can drive the abandonment path without a live DTLS socket.
    func noteTerminalFailure() async {
        isTerminallyFailed = true
        await sendBestEffortStop()
    }

    /// TEST SEAM: seeds an owned session (configID + ownership records) without
    /// a DTLS socket so unit tests can exercise the terminal-failure teardown.
    func seedSessionForTesting(configID: String) {
        self.configID = configID
        // A seeded session stands in for one that really opened, so it has to
        // satisfy the same "did this reach a usable state?" question the
        // production start path now asks. Leaving it `.disconnected` would make
        // every seeded owner look like a failed start.
        state = .streaming
        ownership.registerProcess(bridgeID: bridgeID, configID: configID)
        ownership.recordPersisted(bridgeID: bridgeID, configID: configID)
    }

    private func attemptReconnect() async {
        reconnectTask = nil
        guard case .error = state, !configID.isEmpty else { return }
        log.info("Entertainment reconnect attempt \(self.reconnectAttempts)/\(Self.maxReconnectAttempts)")
        do {
            try await openDTLSConnection()
            reconnectAttempts = 0
            log.info("Entertainment session reconnected")
        } catch {
            log.warning("Reconnect failed: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    // MARK: - Packet Builder

    /// Build a HueStream V2 binary packet.
    private func buildPacket(channels: [(id: UInt8, x: Double, y: Double, brightness: Double)]) -> Data {
        var packet = Data()

        // Header: "HueStream" (9 bytes)
        packet.append(contentsOf: [0x48, 0x75, 0x65, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D])

        // API version 2.0
        packet.append(0x02)  // major
        packet.append(0x00)  // minor

        // Sequence number (wraps at 255)
        packet.append(sequenceNumber)
        sequenceNumber &+= 1

        // Reserved (2 bytes)
        packet.append(0x00)
        packet.append(0x00)

        // Color space: 0x01 = XY + Brightness
        packet.append(0x01)

        // Reserved (1 byte)
        packet.append(0x00)

        // Entertainment area UUID as ASCII (36 bytes, e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
        if let uuidData = configID.data(using: .ascii) {
            // Pad or truncate to exactly 36 bytes
            if uuidData.count >= 36 {
                packet.append(uuidData.prefix(36))
            } else {
                packet.append(uuidData)
                packet.append(contentsOf: [UInt8](repeating: 0x00, count: 36 - uuidData.count))
            }
        } else {
            packet.append(contentsOf: [UInt8](repeating: 0x00, count: 36))
        }

        // Channel data (7 bytes each)
        for channel in channels {
            // Channel ID (1 byte)
            packet.append(channel.id)

            // X coordinate: scale 0.0–1.0 to 0x0000–0xFFFF (big-endian)
            let xInt = UInt16(min(max(channel.x, 0.0), 1.0) * 65535.0)
            packet.append(UInt8(xInt >> 8))
            packet.append(UInt8(xInt & 0xFF))

            // Y coordinate: same scaling
            let yInt = UInt16(min(max(channel.y, 0.0), 1.0) * 65535.0)
            packet.append(UInt8(yInt >> 8))
            packet.append(UInt8(yInt & 0xFF))

            // Brightness: same scaling
            let bInt = UInt16(min(max(channel.brightness, 0.0), 1.0) * 65535.0)
            packet.append(UInt8(bInt >> 8))
            packet.append(UInt8(bInt & 0xFF))
        }

        return packet
    }
}

// MARK: - Errors

enum EntertainmentError: LocalizedError {
    case invalidClientKey
    case invalidUsername
    case connectionFailed
    case dtlsFailed(NWError)
    case timeout
    case cleanupInProgress

    var errorDescription: String? {
        switch self {
        case .invalidClientKey:    return "Invalid entertainment client key format."
        case .invalidUsername:     return "Invalid bridge username encoding."
        case .connectionFailed:   return "Entertainment connection failed."
        case .dtlsFailed(let e):  return "DTLS handshake failed: \(e.localizedDescription)"
        case .timeout:            return "Entertainment connection timed out (10s)."
        case .cleanupInProgress:  return "This lighting session is being cleaned up. Try again in a moment."
        }
    }
}

// MARK: - Data hex helper

extension Data {
    /// Initialize Data from a hexadecimal string (e.g. "E3B5A2..." → 16 bytes).
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespaces)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        for _ in 0..<hex.count / 2 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
