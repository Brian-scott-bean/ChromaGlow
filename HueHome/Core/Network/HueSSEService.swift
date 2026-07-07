// HueSSEService.swift
// CastChroma — Epic 3 / Story 3.2
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
    let type: String               // "light" | "grouped_light" | "button" | "relative_rotary" | …
    let on: SSEOnState?
    let dimming: SSEDimmingState?
    let color: SSEColorState?
    let colorTemp: SSEColorTempState?
    // Round 3 (G): physical-input events (Tap Dial, dimmer switches).
    let button: SSEButtonState?
    let relativeRotary: SSERotaryState?

    enum CodingKeys: String, CodingKey {
        case id, type, on, dimming, color, button
        case colorTemp = "color_temperature"
        case relativeRotary = "relative_rotary"
    }
}

struct SSEOnState: Decodable { let on: Bool }
struct SSEDimmingState: Decodable { let brightness: Double }
struct SSEColorState: Decodable { let xy: SSECIExy }
struct SSECIExy: Decodable { let x: Double; let y: Double }
struct SSEColorTempState: Decodable { let mirek: Int? }

/// `button` resource event: one physical button on a switch/dial.
struct SSEButtonState: Decodable {
    struct Report: Decodable {
        let event: String?   // "initial_press" | "repeat" | "short_release" | "long_press" | "long_release"
    }
    let button_report: Report?
    let last_event: String?  // pre-1.50 firmware fallback

    var event: String? { button_report?.event ?? last_event }
}

/// `relative_rotary` resource event: the Tap Dial's rotating ring.
struct SSERotaryState: Decodable {
    struct Report: Decodable {
        struct Rotation: Decodable {
            let direction: String?   // "clock_wise" | "counter_clock_wise"
            let steps: Int?
            let duration: Int?
        }
        let action: String?          // "start" | "repeat"
        let rotation: Rotation?
    }
    let rotary_report: Report?
    let last_event: LegacyEvent?     // pre-1.50 firmware fallback

    struct LegacyEvent: Decodable {
        let rotation: Report.Rotation?
    }

    var rotation: Report.Rotation? { rotary_report?.rotation ?? last_event?.rotation }
}


// MARK: - HueSSEService

final class HueSSEService: @unchecked Sendable {

    static let shared = HueSSEService()
    private init() {}

    private let log = Logger(subsystem: "com.lightshade.app", category: "SSE")
    /// Shared decoder — JSONDecoder is stateless/thread-safe; reuse avoids heap churn on every SSE frame.
    private static let decoder = JSONDecoder()

    // URLSession with no read/resource timeout — required for indefinite SSE streaming.
    // Pinned bridge trust (H-01/D-016) — shared delegate, never trust-all.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = .infinity
        config.timeoutIntervalForResource = .infinity
        return URLSession(
            configuration: config,
            delegate: BridgePinnedTrustDelegate.shared,
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
                    // L-09: the stream URL embeds the bridge LAN IP — do not log it publicly.
                    self.log.info("SSE: Connecting to bridge event stream.")
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
                            let envelopes = try Self.decoder.decode([SSEEnvelope].self, from: payload)
                            for env in envelopes where env.type == "update" {
                                continuation.yield(env.data)
                            }
                        } catch {
                            // Malformed event — log and keep streaming (non-fatal)
                            self.log.warning("SSE: Parse error — \(error.localizedDescription)")
                        }
                    }

                    self.log.info("SSE: Stream ended.")
                    continuation.finish()

                } catch {
                    self.log.error("SSE: Error — \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
