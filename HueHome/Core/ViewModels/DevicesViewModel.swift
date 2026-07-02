// DevicesViewModel.swift
// CastChroma — Devices Tab
//
// Fetches /clip/v2/resource/device from every active bridge concurrently,
// merges results, and groups them by DeviceType for the UI.

import Foundation
import OSLog
import SwiftUI

@Observable
@MainActor
final class DevicesViewModel {

    // MARK: State
    var devices:      [DeviceDisplayItem] = []
    var isLoading:    Bool    = false
    var errorMessage: String? = nil
    var logLines:     [String] = []

    // MARK: - Dependencies
    private var bridgeClients: [(id: String, api: HueAPIClient)] = []
    private var isDemoMode:    Bool = false
    private let log = Logger(subsystem: "com.lightshade.app", category: "Devices")

    // MARK: - Init
    init() {}

    func configure(bridgeIDs: [String], orchestrator: UnifiedOrchestrator) {
        isDemoMode    = orchestrator.isDemoMode
        bridgeClients = bridgeIDs.compactMap { id in
            guard let api = orchestrator.hueClient(for: id) else { return nil }
            return (id: id, api: api)
        }
    }

    // MARK: - Load

    func loadDevices() async {
        guard !isLoading else { return }
        isLoading    = true
        errorMessage = nil

        if isDemoMode {
            appendLog("✦ Demo: loading mock devices")
            try? await Task.sleep(nanoseconds: 300_000_000)
            devices = DemoDataProvider.devices
            appendLog("✅ Demo: \(devices.count) device(s) loaded")
            isLoading = false
            return
        }

        appendLog("📡 Fetching devices from \(bridgeClients.count) bridge(s)…")

        var merged: [DeviceDisplayItem] = []

        await withTaskGroup(of: [DeviceDisplayItem].self) { group in
            for bridge in bridgeClients {
                group.addTask { [weak self] in
                    await self?.fetchFromBridge(bridge.api, bridgeID: bridge.id) ?? []
                }
            }
            for await items in group { merged.append(contentsOf: items) }
        }

        // Sort: by type order, then alphabetically
        let typeOrder = DeviceDisplayItem.DeviceType.allCases
        devices = merged.sorted {
            let li = typeOrder.firstIndex(of: $0.deviceType) ?? 99
            let ri = typeOrder.firstIndex(of: $1.deviceType) ?? 99
            if li != ri { return li < ri }
            return $0.name < $1.name
        }

        appendLog("✅ \(devices.count) device(s) loaded from \(bridgeClients.count) bridge(s).")
        isLoading = false
    }

    private func fetchFromBridge(_ api: HueAPIClient, bridgeID: String) async -> [DeviceDisplayItem] {
        do {
            let raw = try await api.fetchDevicesRaw()
            appendLog("📡 Bridge \(bridgeID.prefix(8))… \(raw.count) bytes")

            guard let json    = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                appendLog("⚠️ Unexpected shape from bridge \(bridgeID.prefix(8))…")
                return []
            }

            return dataArr.compactMap { item -> DeviceDisplayItem? in
                guard let id = item["id"] as? String else { return nil }

                let meta        = item["metadata"]     as? [String: Any]
                let product     = item["product_data"] as? [String: Any]
                let services    = item["services"]     as? [[String: Any]] ?? []

                let name         = meta?["name"]              as? String
                let productName  = product?["product_name"]   as? String
                let modelID      = product?["model_id"]        as? String
                let firmware     = product?["software_version"] as? String
                let deviceType   = DeviceDisplayItem.DeviceType.from(services: services)

                // Skip the bridge device itself — it's not interesting in the list
                if deviceType == .bridge { return nil }

                return DeviceDisplayItem(
                    id:              "\(bridgeID):\(id)",
                    name:            name ?? productName ?? "Unknown Device",
                    productName:     productName,
                    modelID:         modelID,
                    firmwareVersion: firmware,
                    deviceType:      deviceType,
                    bridgeID:        bridgeID
                )
            }
        } catch {
            appendLog("❌ Bridge \(bridgeID.prefix(8))… failed: \(error.localizedDescription)")
            log.error("Devices bridge \(bridgeID): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Grouped helper

    /// Returns devices grouped by type, preserving type order.
    func grouped() -> [(DeviceDisplayItem.DeviceType, [DeviceDisplayItem])] {
        var dict: [DeviceDisplayItem.DeviceType: [DeviceDisplayItem]] = [:]
        for d in devices { dict[d.deviceType, default: []].append(d) }
        return DeviceDisplayItem.DeviceType.allCases.compactMap { type in
            guard let items = dict[type], !items.isEmpty else { return nil }
            return (type, items)
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
