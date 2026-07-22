// HueSSEService.swift
// ChromaGlow — SSE event models for the Hue V2 event stream
//
// The LIVE SSE connection is UnifiedOrchestrator.runSSE (its own session +
// retry/backoff + rebuild coalescing); these are the decode models it and
// RoomDetailViewModel consume. The old standalone HueSSEService class that
// used to live here was a never-referenced duplicate stream with a latent
// Task/connection leak — deleted in the L-13 close-out (2026-07-22).
//
// Two resource types we care about most:
//   "light"          → individual bulb — consumed by RoomDetailViewModel
//   "grouped_light"  → room-level on/off + brightness — consumed by DashboardViewModel

import Foundation

// MARK: - SSE Event Models

/// A single resource change within an SSE event.
/// Partial — only fields relevant to UI state are decoded; extras are silently ignored.
struct SSEResourceUpdate: Decodable {
    let id: String                 // V2 resource UUID
    let type: String               // "light" | "grouped_light" | "scene" | "button" | …
    let on: SSEOnState?
    let dimming: SSEDimmingState?
    let color: SSEColorState?
    let colorTemp: SSEColorTempState?
    // Scene recall status ("inactive" | "static" | "dynamic_palette") —
    // additive (R5 live-update fix); firmware that omits it decodes to nil.
    let status: SSESceneStatus?
    // Round 3 (G): physical-input events (Tap Dial, dimmer switches).
    let button: SSEButtonState?
    let relativeRotary: SSERotaryState?

    enum CodingKeys: String, CodingKey {
        case id, type, on, dimming, color, button, status
        case colorTemp = "color_temperature"
        case relativeRotary = "relative_rotary"
    }
}

struct SSEOnState: Decodable { let on: Bool }

/// Scene recall status. Other resource types (zigbee_connectivity, …) reuse
/// the "status" key as a plain STRING — a strict object decode would throw
/// and drop the entire event batch, so this init tolerates any shape.
struct SSESceneStatus: Decodable {
    let active: String?   // "inactive" | "static" | "dynamic_palette"

    private enum CodingKeys: String, CodingKey { case active }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            active = (try? container.decodeIfPresent(String.self, forKey: .active)) ?? nil
        } else {
            active = nil
        }
    }
}
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

