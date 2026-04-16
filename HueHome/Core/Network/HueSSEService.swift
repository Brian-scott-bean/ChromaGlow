// HueSSEService.swift
// HueHome Pro — Epic 3 / Story 3.2
//
// Server-Sent Events client for the Hue V2 event stream.
// Endpoint: GET https://{ip}/eventstream/clip/v2
//
// Uses URLSession.bytes(for:) to stream lines from the bridge.
// Yields [SSEResourceUpdate] arrays — one per SSE "data:" line that contains an "update" event.
// The stream throws when the connection drops; callers MUST retry with backoff.
//
// Two resource types we care about:
//   "light"          → individual bulb — consumed by RoomDetailViewModel
//   "grouped_light"  → room-level on/off + brightness — consumed by DashboardViewModel

import Foundation
import OSLog

// MARK: - SSE Event Models

/// Top-level SSE envelope. One data: line can contain multiple envelopes.
struct SSEEnvelope: Decodable {
    let type: String               // "update" | "add" | "delete" | "error"
    let data: [SSEResourceUpdate]
}

/// A single resource change within an SSE event.
/// Partial — only fields relevant to UI state are decoded; extras are silently ignored.
struct SSEResourceUpdate: Decodable {
    let id: String                 // V2 resource UUID
    let type: String               // "light" | "grouped_light" | "room" | …
    let on: SSEOnState?
    let dimming: SSEDimmingState?
    let color: SSEColorState?
    let colorTemp: SSEColorTempState?

    enum CodingKeys: String, CodingKey {
        case id, type, on, dimming, color
        case colorTemp = "color_temperature"
    }
}

struct SSEOnState: Decodable { let on: Bool }
struct SSEDimmingState: Decodable { let brightness: Double }
struct SSEColorState: Decodable { let xy: SSECIExy }
struct SSECIExy: Decodable { let x: Double; let y: Double }
struct SSEColorTempState: Decodable { let mirek: Int? }


// MARK: - HueSSEService

final class HueSSEService: @unchecked Sendable {

    static let shared = HueSSEService()
    private init() {}

    private let log = Logger(subsystem: "com.huehome.pro", category: "SSE")

    // URLSession with no read/resource timeout — required for indefinite SSE streaming.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = .infinity
        config.timeoutIntervalForResource = .infinity
        return URLSession(
            configuration: config,
            delegate: HueCertTrustDelegate(),   // reuse bridge self-signed cert trust
            delegateQueue: nil
        )
    }()

    // ──────────────────────────────────────────────
    // MARK: - Event Stream
    // ──────────────────────────────────────────────

    /// Opens a persistent SSE connection to the Bridge and yields resource-update arrays.
    /// Each yield corresponds to one "update" SSE event.
    /// The stream finishes (with or without an error) when the connection drops.
    /// Callers should retry with exponential backoff.
    func events(ip: String, token: String) -> AsyncThrowingStream<[SSEResourceUpdate], Error> {
        AsyncThrowingStream { continuation in
            Task {
                let urlStr = "https://\(ip)/eventstream/clip/v2"
                guard let url = URL(string: urlStr) else {
                    continuation.finish(throwing: HueAPIError.badURL(urlStr))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(token,               forHTTPHeaderField: "hue-application-key")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                do {
                    self.log.info("SSE: Connecting to \(urlStr, privacy: .public)")
                    let (bytes, _) = try await self.session.bytes(for: request)

                    for try await line in bytes.lines {
                        // SSE line format:
                        //   "data: [...]"  → payload
                        //   "id: ..."      → event ID
                        //   ": hi"         → Bridge keepalive comment
                        //   ""             → event boundary
                        guard line.hasPrefix("data:") else { continue }

                        let jsonStr = String(line.dropFirst(5))
                            .trimmingCharacters(in: .whitespaces)
                        guard !jsonStr.isEmpty,
                              let payload = jsonStr.data(using: .utf8) else { continue }

                        do {
                            let envelopes = try JSONDecoder().decode([SSEEnvelope].self, from: payload)
                            for env in envelopes where env.type == "update" {
                                continuation.yield(env.data)
                            }
                        } catch {
                            // Malformed event — log and keep streaming (non-fatal)
                            self.log.warning("SSE: Parse error — \(error.localizedDescription, privacy: .public)")
                        }
                    }

                    self.log.info("SSE: Stream ended.")
                    continuation.finish()

                } catch {
                    self.log.error("SSE: Error — \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
