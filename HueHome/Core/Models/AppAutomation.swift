// AppAutomation.swift
// LightShade — User-created scheduled automations stored locally in SwiftData.
// Each automation fires at a given time on selected weekdays and applies a
// preset or effect to all rooms via the Hue API.

import SwiftUI
import SwiftData

// MARK: - AppAutomation

@Model
final class AppAutomation {

    // MARK: Identity
    var id:        UUID    = UUID()
    var name:      String  = ""
    var isEnabled: Bool    = true
    var createdAt: Date    = Date()

    // MARK: Schedule — stored as hour/minute ints for easy UNCalendar use
    var hour:     Int    = 8
    var minute:   Int    = 0
    /// Calendar weekday values: 1=Sunday … 7=Saturday
    /// Stored as comma-separated string because SwiftData can't store [Int] on older runtimes.
    var weekdaysRaw: String = "2,3,4,5,6"   // Mon–Fri default

    // MARK: Action
    var actionTypeRaw: String  = AutomationAction.preset("energize").rawCategory
    var presetID:      String? = "energize"   // "energize" | "read" | "relax" | "sleep"
    var effectID:      String? = nil          // HueEffect.id

    // MARK: Computed helpers

    var weekdays: [Int] {
        get { weekdaysRaw.split(separator: ",").compactMap { Int($0) } }
        set { weekdaysRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    var action: AutomationAction {
        get {
            if let p = presetID, actionTypeRaw == "preset" { return .preset(p) }
            if let e = effectID, actionTypeRaw == "effect" { return .effect(e) }
            return .preset("relax")
        }
        set {
            switch newValue {
            case .preset(let id): actionTypeRaw = "preset"; presetID = id; effectID = nil
            case .effect(let id): actionTypeRaw = "effect"; effectID = id; presetID = nil
            }
        }
    }

    /// Human-readable time, e.g. "8:30 AM"
    var timeLabel: String {
        var comps        = DateComponents()
        comps.hour       = hour
        comps.minute     = minute
        let date         = Calendar.current.date(from: comps) ?? Date()
        let fmt          = DateFormatter()
        fmt.timeStyle    = .short
        fmt.dateStyle    = .none
        return fmt.string(from: date)
    }

    /// Abbreviated day list, e.g. "Mon, Wed, Fri"
    var daysLabel: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2,3,4,5,6] { return "Weekdays" }
        if weekdays == [1,7] { return "Weekends" }
        return weekdays.compactMap { names[safeIndex: $0 - 1] }.joined(separator: ", ")
    }

    init(name: String = "", hour: Int = 8, minute: Int = 0,
         weekdays: [Int] = [2,3,4,5,6], action: AutomationAction = .preset("energize")) {
        self.id        = UUID()
        self.name      = name
        self.hour      = hour
        self.minute    = minute
        self.weekdays  = weekdays
        self.action    = action
        self.createdAt = Date()
    }
}

// MARK: - AutomationAction

enum AutomationAction: Equatable {
    case preset(String)   // presetID: energize | read | relax | sleep
    case effect(String)   // HueEffect.id

    var rawCategory: String {
        switch self { case .preset: return "preset"; case .effect: return "effect" }
    }

    var displayName: String {
        switch self {
        case .preset(let id): return id.capitalized
        case .effect(let id): return EffectLibrary.all.first(where: { $0.id == id })?.name ?? id
        }
    }

    var icon: String {
        switch self {
        case .preset(let id):
            switch id {
            case "energize": return "bolt.fill"
            case "read":     return "book.fill"
            case "relax":    return "moon.stars.fill"
            case "sleep":    return "zzz"
            default:         return "lightbulb.fill"
            }
        case .effect(let id):
            return EffectLibrary.all.first(where: { $0.id == id })?.icon ?? "sparkles"
        }
    }
}

