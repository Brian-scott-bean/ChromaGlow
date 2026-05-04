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

    private let log = Logger(subsystem: "com.lightshade.app", category: "Entertainment")

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
        state = .connecting
        log.info("Starting entertainment session for config \(configID)")

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
            state = .error("Failed to activate: \(error.localizedDescription)")
            log.error("REST activate failed: \(error.localizedDescription)")
            throw error
        }

        // Step 2: Open DTLS connection
        try await openDTLSConnection()
    }

    /// Stop the streaming session.
    /// 1. Close DTLS connection
    /// 2. PUT /entertainment_configuration/{id} action=stop via REST
    func stopSession() async {
        log.info("Stopping entertainment session")

        // Close DTLS
        connection?.cancel()
        connection = nil

        // Deactivate via REST (best effort)
        if !configID.isEmpty {
            do {
                let (ip, token) = try restClient.credentials()
                let body: [String: Any] = ["action": "stop"]
                _ = try await restClient.put(
                    path: "/clip/v2/resource/entertainment_configuration/\(configID)",
                    body: body, ip: ip, token: token
                )
            } catch {
                log.warning("REST deactivate failed (non-fatal): \(error.localizedDescription)")
            }
        }

        state = .disconnected
        sequenceNumber = 0
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

    private func openDTLSConnection() async throws {
        // Convert hex client key to binary
        guard let pskData = Data(hexString: clientKeyHex) else {
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

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false

            conn.stateUpdateHandler = { [weak self] newState in
                guard let self, !resumed else { return }
                switch newState {
                case .ready:
                    resumed = true
                    Task { await self.setStreaming(conn) }
                    continuation.resume()

                case .failed(let error):
                    resumed = true
                    Task { await self.setError("DTLS failed: \(error.localizedDescription)") }
                    continuation.resume(throwing: EntertainmentError.dtlsFailed(error))

                case .waiting(let error):
                    // Waiting usually means handshake in progress — log but don't fail yet
                    Task {
                        await self.logMessage("DTLS waiting: \(error.localizedDescription)")
                    }

                case .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: EntertainmentError.connectionFailed)
                    }

                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInteractive))

            // Timeout after 10 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard !resumed else { return }
                resumed = true
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
        state = .error("Send failed")
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
