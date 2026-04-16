// HueBehaviorInstance.swift
// HueHome Pro — Epic 6
//
// Typed model for GET /clip/v2/resource/behavior_instance.
// A "behavior instance" is a configured automation on the Bridge —
// schedules, wake-up routines, tap-to-runs, circadian cycles, etc.
//
// The `configuration` field is left as a raw JSON blob (AnyCodable-style)
// because its shape depends on the script_id. We only surface the parts
// the UI actually needs: name, enabled status, and script type.

import Foundation

// MARK: - HueBehaviorInstance

struct HueBehaviorInstance: Decodable, Identifiable {
    let id:        String
    let metadata:  BehaviorMetadata?  // absent on some firmware versions
    let enabled:   Bool
    let script_id: String?
    let status:    BehaviorStatus?

    var displayName: String { metadata?.name ?? "Unnamed Automation" }
}

struct BehaviorMetadata: Decodable {
    let name:     String?   // occasionally absent
    let category: String?
}

struct BehaviorStatus: Decodable {
    let action:     String?
    let last_error: String?
}

// MARK: - Display Model

struct AutomationDisplayItem: Identifiable {
    let id:       String
    let name:     String
    var enabled:  Bool
    let category: AutomationCategory
    let status:   String?   // "running" | "waiting" | "stopped" | nil

    enum AutomationCategory: String {
        case wakeUp     = "Wake-up"
        case sleep      = "Sleep"
        case circadian  = "Circadian"
        case schedule   = "Schedule"
        case timer      = "Timer"
        case tapToRun   = "Shortcut"
        case other      = "Automation"

        /// Infer from script_id string
        static func from(scriptID: String?) -> AutomationCategory {
            guard let id = scriptID?.lowercased() else { return .other }
            if id.contains("wakeup") || id.contains("wake_up") { return .wakeUp }
            if id.contains("sleep") || id.contains("go_to_sleep") { return .sleep }
            if id.contains("natural_light") || id.contains("circadian") { return .circadian }
            if id.contains("timer") { return .timer }
            if id.contains("tap") || id.contains("shortcut") { return .tapToRun }
            if id.contains("schedule") { return .schedule }
            return .other
        }

        var icon: String {
            switch self {
            case .wakeUp:    return "sun.and.horizon.fill"
            case .sleep:     return "moon.fill"
            case .circadian: return "sun.max.fill"
            case .schedule:  return "calendar.badge.clock"
            case .timer:     return "timer"
            case .tapToRun:  return "hand.tap.fill"
            case .other:     return "bolt.fill"
            }
        }

        var color: String {   // used for icon tint selection in UI
            switch self {
            case .wakeUp:    return "orange"
            case .sleep:     return "indigo"
            case .circadian: return "yellow"
            case .schedule:  return "blue"
            case .timer:     return "teal"
            case .tapToRun:  return "purple"
            case .other:     return "amber"
            }
        }
    }
}
