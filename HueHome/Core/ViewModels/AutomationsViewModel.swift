// AutomationsViewModel.swift
// HueHome Pro — Epic 6
//
// Fetches behavior_instance resources from the Bridge and manages
// enable/disable toggling with optimistic UI updates.

import Foundation
import OSLog
import SwiftUI

@Observable
@MainActor
final class AutomationsViewModel {

    // MARK: State
    var automations: [AutomationDisplayItem] = []
    var isLoading:    Bool    = false
    var errorMessage: String? = nil
    var logLines:     [String] = []

    // MARK: - Dependencies

    private let api  = HueAPIClient.shared
    private let log  = Logger(subsystem: "com.huehome.pro", category: "Automations")

    // MARK: - Load

    func loadAutomations() async {
        guard !isLoading else { return }
        isLoading    = true
        errorMessage = nil
        appendLog("⚡ Fetching automations from Bridge…")

        do {
            let raw = try await api.fetchAutomationsRaw()
            appendLog("⚡ Raw data received (\(raw.count) bytes)")

            // JSONSerialization is completely schema-free:
            // unknown fields, variable types, and missing optionals are all handled
            // gracefully. Each item is parsed independently via compactMap so one
            // bad item never aborts the whole list.
            guard let json    = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                throw NSError(domain: "com.huehome.pro",
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "behavior_instance response had unexpected top-level shape"])
            }

            appendLog("⚡ Total behavior_instances: \(dataArr.count)")

            automations = dataArr.compactMap { item -> AutomationDisplayItem? in
                guard let id      = item["id"]      as? String,
                      let enabled = item["enabled"] as? Bool else { return nil }

                let meta     = item["metadata"] as? [String: Any]
                let name     = meta?["name"]     as? String ?? "Unnamed Automation"
                let scriptID = item["script_id"] as? String
                let statusD  = item["status"]    as? [String: Any]
                let action   = statusD?["action"] as? String

                return AutomationDisplayItem(
                    id:       id,
                    name:     name,
                    enabled:  enabled,
                    category: .from(scriptID: scriptID),
                    status:   action
                )
            }
            .sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled { return lhs.enabled }
                return lhs.name < rhs.name
            }

            appendLog("✅ \(automations.count) automation(s) loaded.")
        } catch {
            let msg = error.localizedDescription
            appendLog("❌ Load failed: \(msg)")
            log.error("Automations: \(msg, privacy: .public)")
            errorMessage = msg
        }

        isLoading = false
    }

    // MARK: - Toggle

    func toggle(_ item: AutomationDisplayItem) {
        let newEnabled = !item.enabled

        // Optimistic update
        if let idx = automations.firstIndex(where: { $0.id == item.id }) {
            automations[idx].enabled = newEnabled
        }
        appendLog("\(newEnabled ? "✅" : "⏸") '\(item.name)' → \(newEnabled ? "enabled" : "disabled")")

        Task {
            do {
                try await api.setAutomation(id: item.id, enabled: newEnabled)
                log.info("Automations: '\(item.name, privacy: .public)' → \(newEnabled, privacy: .public)")
            } catch {
                // Rollback
                appendLog("❌ Toggle failed: \(error.localizedDescription)")
                if let idx = automations.firstIndex(where: { $0.id == item.id }) {
                    automations[idx].enabled = !newEnabled
                }
            }
        }
    }

    // MARK: - Logging

    private func appendLog(_ message: String) {
        let ts   = DateFormatter.logTime.string(from: Date())
        let line = "[\(ts)] \(message)"
        logLines.append(line)
        print(line)
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
