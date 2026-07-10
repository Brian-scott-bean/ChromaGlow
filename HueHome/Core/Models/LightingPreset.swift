// LightingPreset.swift
// ChromaGlow — the four built-in lighting presets
//
// Energize / Read / Relax / Sleep existed as four separate hand-synced copies:
// DashboardView (chips), AutomationHandler (AutomationPreset), the widget's
// ApplyPresetIntent params, and WatchStore's WatchPreset. They agreed today
// because nobody had touched one without the others yet.
//
// This file is the single definition. It is pure Foundation and belongs to the
// app, widget, AND watch targets (registered in all three source phases), so
// every surface reads the same numbers. UI-only concerns (SwiftUI Color,
// AppEnum display representations) stay in each surface — colors are styling,
// brightness/mirek are behavior.

import Foundation

struct LightingPreset: Identifiable, Equatable, Sendable {
    /// Stable id — persisted in widget configurations and automation payloads.
    /// Do not rename values.
    let id: String
    let name: String
    /// SF Symbol.
    let icon: String
    /// 1–100.
    let brightness: Double
    /// Color temperature, mirek (153 cool … 500 warm).
    let mirek: Int

    static let energize = LightingPreset(id: "energize", name: "Energize", icon: "bolt.fill",       brightness: 100, mirek: 156)
    static let read     = LightingPreset(id: "read",     name: "Read",     icon: "book.fill",       brightness: 75,  mirek: 280)
    static let relax    = LightingPreset(id: "relax",    name: "Relax",    icon: "moon.stars.fill", brightness: 40,  mirek: 420)
    static let sleep    = LightingPreset(id: "sleep",    name: "Sleep",    icon: "zzz",             brightness: 6,   mirek: 490)

    static let all: [LightingPreset] = [.energize, .read, .relax, .sleep]

    static func find(_ id: String) -> LightingPreset? {
        all.first { $0.id == id }
    }
}
