// DeviceDisplayItem.swift
// CastChroma — Devices Tab
//
// UI-facing model for a Hue paired device.
// Parsed from GET /clip/v2/resource/device.

import Foundation

// MARK: - DeviceDisplayItem

struct DeviceDisplayItem: Identifiable {
    let id:              String
    let name:            String
    let productName:     String?
    let modelID:         String?
    let firmwareVersion: String?  // e.g. "1.104.2"
    let deviceType:      DeviceType
    let bridgeID:        String?  // which bridge it came from

    // MARK: - Device Type

    enum DeviceType: String, CaseIterable {
        case light   = "Lights"
        case control = "Controls"
        case sensor  = "Sensors"
        case bridge  = "Bridge"
        case other   = "Other"

        /// Infer from the services array returned by the bridge.
        static func from(services: [[String: Any]]) -> DeviceType {
            let types = services.compactMap { $0["rtype"] as? String }
            if types.contains("light")   { return .light   }
            if types.contains("button")  { return .control }
            if types.contains("relative_rotary") { return .control }
            if types.contains("motion") || types.contains("temperature")
                                         { return .sensor  }
            if types.contains("bridge")  { return .bridge  }
            return .other
        }

        var icon: String {
            switch self {
            case .light:   return "lightbulb.fill"
            case .control: return "button.horizontal.top.press.fill"
            case .sensor:  return "sensor.fill"
            case .bridge:  return "rectangle.connected.to.line.below"
            case .other:   return "cpu.fill"
            }
        }

        var colorKey: String {
            switch self {
            case .light:   return "amber"
            case .control: return "blue"
            case .sensor:  return "teal"
            case .bridge:  return "purple"
            case .other:   return "white"
            }
        }
    }

    // MARK: - Formatted firmware

    /// Strips long build hashes — shows only semver portion (e.g. "1.101.2" from "1.101.2115080080").
    var firmwareShort: String? {
        guard let v = firmwareVersion else { return nil }
        // Keep only the first three dot-separated components
        let parts = v.split(separator: ".").prefix(3).joined(separator: ".")
        return parts.isEmpty ? v : parts
    }
}
