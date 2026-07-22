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

    // MARK: - App-owned session registry (M-06)
    //
    // Every entertainment configuration this app is actively using, so the
    // orchestrator's stuck-session cleanup can never stop the app's own
    // Studio/Composer/Sync session mid-show. Reference-counted: two client
    // instances can target the same configuration (Sync engine + Studio), and
    // one instance stopping must not expose the other's live session to the
    // cleanup pass.
    private static let activeSessionsLock = NSLock()
    nonisolated(unsafe) private static var activeSessionRefCounts: [String: Int] = [:]

    static func registerActiveSession(configID: String) {
        activeSessionsLock.lock()
        defer { activeSessionsLock.unlock() }
        activeSessionRefCounts[configID, default: 0] += 1
    }

    static func unregisterActiveSession(configID: String) {
        activeSessionsLock.lock()
        defer { activeSessionsLock.unlock() }
        guard let count = activeSessionRefCounts[configID] else { return }
        if count <= 1 {
            activeSessionRefCounts.removeValue(forKey: configID)
        } else {
            activeSessionRefCounts[configID] = count - 1
        }
    }

    /// True when THIS app process owns an active streaming session for the
    /// given entertainment configuration.
    static func isAppOwnedSession(configID: String) -> Bool {
        activeSessionsLock.lock()
        defer { activeSessionsLock.unlock() }
        return activeSessionRefCounts[configID] != nil
    }

    // MARK: Init

    init(bridgeIP: String, username: String, clientKeyHex: String, restClient: HueAPIClient) {
        self.bridgeIP = bridgeIP
        self.username = username
        self.clientKeyHex = clientKeyHex
        self.restClient = restClient
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
        Self.registerActiveSession(configID: configID)

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
            Self.unregisterActiveSession(configID: configID)
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

    /// Shared session teardown: unregister from the app-owned registry,
    /// best-effort `action=stop` on the bridge, reset configID. Used by
    /// stopSession, the failed-open rollback (L-11), and reconnect
    /// abandonment (M-10) so the teardown protocol cannot drift.
    private func sendBestEffortStop() async {
        guard !configID.isEmpty else { return }
        Self.unregisterActiveSession(configID: configID)
        do {
            let (ip, token) = try restClient.credentials()
            let body: [String: Any] = ["action": "stop"]
            _ = try await restClient.put(
                path: "/clip/v2/resource/entertainment_configuration/\(configID)",
                body: body, ip: ip, token: token
            )
            log.info("Entertainment action=stop sent")
        } catch {
            log.warning("action=stop failed (bridge inactivity timeout will recover): \(error.localizedDescription)")
        }
        configID = ""
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
                    Task { await self.setStreaming(conn) }
                    continuation.resume()

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

    /// TEST SEAM: seeds an owned session (configID + registry entry) without
    /// a DTLS socket so unit tests can exercise the terminal-failure teardown.
    func seedSessionForTesting(configID: String) {
        self.configID = configID
        Self.registerActiveSession(configID: configID)
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

    var errorDescription: String? {
        switch self {
        case .invalidClientKey:    return "Invalid entertainment client key format."
        case .invalidUsername:     return "Invalid bridge username encoding."
        case .connectionFailed:   return "Entertainment connection failed."
        case .dtlsFailed(let e):  return "DTLS handshake failed: \(e.localizedDescription)"
        case .timeout:            return "Entertainment connection timed out (10s)."
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
