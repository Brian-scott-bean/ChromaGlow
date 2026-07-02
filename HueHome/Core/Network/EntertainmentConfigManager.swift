// EntertainmentConfigManager.swift
// CastChroma — Entertainment Configuration REST Manager
//
// Fetches entertainment_configuration resources from the Hue Bridge V2 API.
// Phase 1: read-only — lists existing configs created via the Hue app.
// Phase 2 (round-2 checkpoint Item 4): rename + delete for the in-app
// Entertainment Areas management screen. Create lives in
// EntertainmentConfigBuilderView.

import Foundation
import os

// MARK: - EntertainmentConfigManager

struct EntertainmentConfigManager: Sendable {

    private let log = Logger(subsystem: "com.lightshade.app", category: "EntConfig")

    /// Fetch all entertainment configurations from a bridge.
    func fetchConfigs(client: HueAPIClient) async throws -> [EntertainmentConfig] {
        let (ip, token) = try client.credentials()
        let data = try await client.get(
            path: "/clip/v2/resource/entertainment_configuration",
            ip: ip, token: token
        )

        // Decode the raw JSON — use manual parsing for resilience
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            log.warning("No entertainment configs found or decode failed")
            return []
        }

        return items.compactMap { parseConfig($0) }
    }

    /// Rename an entertainment configuration on the bridge.
    func rename(configID: String, to name: String, client: HueAPIClient) async throws {
        let (ip, token) = try client.credentials()
        _ = try await client.put(
            path: "/clip/v2/resource/entertainment_configuration/\(configID)",
            body: ["metadata": ["name": name]],
            ip: ip, token: token
        )
        log.info("Renamed entertainment config \(configID, privacy: .public)")
    }

    /// Delete an entertainment configuration from the bridge.
    func delete(configID: String, client: HueAPIClient) async throws {
        let (ip, token) = try client.credentials()
        _ = try await client.delete(
            path: "/clip/v2/resource/entertainment_configuration/\(configID)",
            ip: ip, token: token
        )
        log.info("Deleted entertainment config \(configID, privacy: .public)")
    }

    // MARK: - Parsing

    private func parseConfig(_ dict: [String: Any]) -> EntertainmentConfig? {
        guard let id = dict["id"] as? String else { return nil }

        // Name
        let metadata = dict["metadata"] as? [String: Any]
        let name = metadata?["name"] as? String ?? "Unnamed Area"

        // Channels
        let channelsRaw = dict["channels"] as? [[String: Any]] ?? []
        let channels = channelsRaw.compactMap { parseChannel($0) }

        return EntertainmentConfig(id: id, name: name, channels: channels)
    }

    private func parseChannel(_ dict: [String: Any]) -> EntertainmentChannel? {
        guard let channelID = dict["channel_id"] as? Int else { return nil }

        // Members — each member has a "service" with an "rid" pointing to the light resource
        let members = dict["members"] as? [[String: Any]] ?? []
        let lightServiceIDs = members.compactMap { member -> String? in
            let service = member["service"] as? [String: Any]
            return service?["rid"] as? String
        }

        // Position
        let posDict = dict["position"] as? [String: Any]
        let x = posDict?["x"] as? Double ?? 0.0
        let y = posDict?["y"] as? Double ?? 0.0
        let z = posDict?["z"] as? Double ?? 0.0

        return EntertainmentChannel(
            id: channelID,
            lightServiceIDs: lightServiceIDs,
            position: (x: x, y: y, z: z)
        )
    }
}
