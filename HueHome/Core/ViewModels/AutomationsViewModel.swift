// AutomationsViewModel.swift
// CastChroma — Epic 6 (updated: orchestrator wiring + multi-bridge + demo mode)
//
// Fetches behavior_instance resources from every active Bridge and merges
// them into a single sorted list. Enable/disable toggling uses optimistic UI.

import Foundation
import OSLog
import SwiftUI

@Observable
@MainActor
final class AutomationsViewModel {

    // MARK: State
    var automations:  [AutomationDisplayItem] = []
    var isLoading:    Bool    = false
    var errorMessage: String? = nil
    var logLines:     [String] = []

    // MARK: - Dependencies
    // Injected from AutomationsTabView via orchestrator — one entry per active bridge.
    // Nil client = demo mode for that slot (unused; demo uses the isDemoMode flag).
    private var bridgeClients: [(id: String, api: HueAPIClient)] = []
    private var isDemoMode:    Bool = false
    private let log = Logger(subsystem: "com.lightshade.app", category: "Automations")

    // MARK: - Init

    init() {}

    /// Called from AutomationsTabView once the orchestrator is available.
    func configure(bridgeIDs: [String], orchestrator: UnifiedOrchestrator) {
        isDemoMode    = orchestrator.isDemoMode
        bridgeClients = bridgeIDs.compactMap { id in
            guard let api = orchestrator.hueClient(for: id) else { return nil }
            return (id: id, api: api)
        }
    }

    // MARK: - Load

    func loadAutomations() async {
        guard !isLoading else { return }
        isLoading    = true
        errorMessage = nil

        // Demo mode: return mock data instantly
        if isDemoMode {
            appendLog("✦ Demo: loading mock automations")
            try? await Task.sleep(nanoseconds: 350_000_000)  // brief fake delay
            automations = DemoDataProvider.automations
            appendLog("✅ Demo: \(automations.count) automation(s) loaded")
            isLoading = false
            return
        }

        appendLog("⚡ Fetching automations from \(bridgeClients.count) bridge(s)…")

        var merged: [AutomationDisplayItem] = []

        // Fetch from all bridges concurrently
        await withTaskGroup(of: [AutomationDisplayItem].self) { group in
            for bridge in bridgeClients {
                group.addTask { [weak self] in
                    await self?.fetchFromBridge(bridge.api, bridgeID: bridge.id) ?? []
                }
            }
            for await items in group { merged.append(contentsOf: items) }
        }

        automations = merged.sorted {
            if $0.enabled != $1.enabled { return $0.enabled }
            return $0.name < $1.name
        }

        appendLog("✅ \(automations.count) automation(s) loaded across \(bridgeClients.count) bridge(s).")
        isLoading = false
    }

    private func fetchFromBridge(_ api: HueAPIClient, bridgeID: String) async -> [AutomationDisplayItem] {
        do {
            let raw = try await api.fetchAutomationsRaw()
            appendLog("⚡ Bridge \(bridgeID.prefix(8))… \(raw.count) bytes")

            guard let json    = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                appendLog("⚠️ Unexpected response shape from bridge \(bridgeID.prefix(8))…")
                return []
            }

            return dataArr.compactMap { item -> AutomationDisplayItem? in
                guard let id      = item["id"]      as? String,
                      let enabled = item["enabled"] as? Bool else { return nil }
                let meta     = item["metadata"] as? [String: Any]
                let name     = meta?["name"]     as? String ?? "Unnamed Automation"
                let scriptID = item["script_id"] as? String
                let statusD  = item["status"]    as? [String: Any]
                let action   = statusD?["action"] as? String

                return AutomationDisplayItem(
                    id:       "\(bridgeID):\(id)",   // namespace by bridge so IDs are globally unique
                    name:     name,
                    enabled:  enabled,
                    category: .from(scriptID: scriptID),
                    status:   action,
                    bridgeAutomationID: id,           // raw bridge ID for API calls
                    bridgeID: bridgeID
                )
            }
        } catch {
            appendLog("❌ Bridge \(bridgeID.prefix(8))… load failed: \(error.localizedDescription)")
            log.error("Automations bridge \(bridgeID): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Toggle

    func toggle(_ item: AutomationDisplayItem) {
        let newEnabled = !item.enabled

        // Optimistic update
        if let idx = automations.firstIndex(where: { $0.id == item.id }) {
            automations[idx].enabled = newEnabled
        }
        appendLog("\(newEnabled ? "✅" : "⏸") '\(item.name)' → \(newEnabled ? "enabled" : "disabled")")

        // Demo mode: no API call
        guard !isDemoMode else { return }

        // Find the right bridge client for this automation
        let bridgeID = item.bridgeID ?? ""
        guard let bridge = bridgeClients.first(where: { $0.id == bridgeID }),
              let rawID  = item.bridgeAutomationID else {
            appendLog("⚠️ No bridge client for '\(item.name)'")
            return
        }

        Task {
            do {
                try await bridge.api.setAutomation(id: rawID, enabled: newEnabled)
                log.info("Automations: '\(item.name)' → \(newEnabled)")
            } catch {
                appendLog("❌ Toggle failed: \(error.localizedDescription)")
                // Rollback
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
#if DEBUG
        print(line)
#endif
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
