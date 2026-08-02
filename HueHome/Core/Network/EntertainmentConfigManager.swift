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

        // Decode the raw JSON — use manual parsing for resilience.
        //
        // A decode failure THROWS rather than returning []: the caller has to
        // tell "the bridge genuinely has no areas" (→ availability may say no)
        // apart from "we could not read the answer" (→ availability must stay
        // unknown). Collapsing both to an empty array is what let a bridge that
        // times out report "this bridge has no entertainment area yet".
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            log.warning("Entertainment config list could not be decoded")
            throw HueAPIError.decodingFailed("entertainment_configuration")
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

        // Members — each member's "service.rid" is an **entertainment** service
        // rid, NOT a light rid, despite the field it lands in being called
        // `lightServiceIDs`. Resolve it through
        // `EntertainmentAreaSelector.entertainmentToLightMap` before comparing
        // it with anything light-shaped. (Renaming the field repo-wide is out
        // of scope for Composer 2 packet 1b.)
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

// MARK: - EntertainmentAreaSelector

/// Room-aware Entertainment Area selection, and the resource-ID join it needs.
///
/// **The naming hazard this type exists to contain.** `EntertainmentChannel.lightServiceIDs`
/// does not hold light rids — `parseChannel` above fills it from `members[].service.rid`,
/// which is an *entertainment* service rid. Comparing those values directly with
/// `HueLight.id`, `RoomDisplayItem.childResourceRefs`, or resolved room light IDs yields the
/// empty set for every room on every bridge — a selector built that way returns nil always
/// and silently disables Entertainment app-wide. The only correct route is the join:
///
///     entertainment service --owner.rid--> device <--owner.rid-- light service
///
/// Every consumer — area selection, availability, channel IDs, spatial positions — goes
/// through this one namespace, so selection and streaming can never disagree about which
/// lights an area actually contains.
///
/// Everything here is pure: no networking, no global state, and no dependence on the order
/// the bridge happened to return its resources in.
enum EntertainmentAreaSelector {

    // ─────────────────────────────────────────────────────────
    // MARK: - The mapping
    // ─────────────────────────────────────────────────────────

    /// entertainmentServiceID → deviceID, from `GET /clip/v2/resource/entertainment`.
    static func entertainmentServiceOwners(from data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [:] }

        var owners: [String: String] = [:]
        for item in items {
            guard let entID = item["id"] as? String,
                  let owner = item["owner"] as? [String: Any],
                  let deviceID = owner["rid"] as? String else { continue }
            owners[entID] = deviceID
        }
        return owners
    }

    /// deviceID → lightID.
    ///
    /// A device can own more than one light service (multi-head fixtures). The map is
    /// single-valued by design — the cached membership shape is one light per entertainment
    /// service — so the collapse resolves to the *lowest* light ID rather than whichever
    /// element happened to come last. Last-writer-wins would make the whole selection depend
    /// on the order `/resource/light` was returned in, which is exactly what this packet
    /// forbids. (Consequence: an area covering such a device maps to a strict subset of the
    /// room's lights, so it is selected by the subset stage instead of the exact stage —
    /// still safe, just not an exact match.)
    static func deviceToLightID(lights: [HueLight]) -> [String: String] {
        var map: [String: String] = [:]
        for light in lights {
            guard let deviceID = light.owner?.rid else { continue }
            if let existing = map[deviceID], existing <= light.id { continue }
            map[deviceID] = light.id
        }
        return map
    }

    /// entertainmentServiceID → lightID — the join both selection and spatial positions use.
    static func entertainmentToLightMap(
        entertainmentServiceOwners: [String: String],
        lights: [HueLight]
    ) -> [String: String] {
        let deviceToLight = deviceToLightID(lights: lights)
        var map: [String: String] = [:]
        for (entServiceID, deviceID) in entertainmentServiceOwners {
            // An entertainment service whose device owns no light we know about is
            // dropped, not guessed at — a stale or unresolvable member must never
            // manufacture a match.
            guard let lightID = deviceToLight[deviceID] else { continue }
            map[entServiceID] = lightID
        }
        return map
    }

    // ─────────────────────────────────────────────────────────
    // MARK: - Derived facts about one config
    // ─────────────────────────────────────────────────────────

    /// The real light IDs an area actually contains, resolved through the join.
    static func mappedLightIDs(
        for config: EntertainmentConfig,
        entertainmentToLightMap: [String: String]
    ) -> Set<String> {
        var ids: Set<String> = []
        for channel in config.channels {
            for entServiceID in channel.lightServiceIDs {
                if let lightID = entertainmentToLightMap[entServiceID] { ids.insert(lightID) }
            }
        }
        return ids
    }

    /// lightID → physical (x, z), for the motion/spatial engines.
    static func lightPositions(
        for config: EntertainmentConfig,
        entertainmentToLightMap: [String: String]
    ) -> [String: (x: Double, z: Double)] {
        var result: [String: (x: Double, z: Double)] = [:]
        for channel in config.channels {
            for entServiceID in channel.lightServiceIDs {
                if let lightID = entertainmentToLightMap[entServiceID] {
                    result[lightID] = (x: channel.position.x, z: channel.position.z)
                }
            }
        }
        return result
    }

    /// The DTLS channel IDs for a config, or nil when the config cannot be streamed at all.
    ///
    /// Returns nil — never a partial list — when there are no channels, when any `channel_id`
    /// falls outside `UInt8`, or when the IDs are not unique. Streaming a config after
    /// silently dropping members would light some of an area and leave the rest dark, and
    /// dropping one would break the index alignment that
    /// `CompositionEngine.computeSpatialPositionsForEntertainment(channels:)` relies on.
    /// The trapping `UInt8(_:)` initialiser is deliberately not used: `channel_id` comes
    /// straight from bridge JSON as an `Int`.
    static func validatedChannelIDs(for config: EntertainmentConfig) -> [UInt8]? {
        guard !config.channels.isEmpty else { return nil }

        var ids: [UInt8] = []
        ids.reserveCapacity(config.channels.count)
        for channel in config.channels {
            guard let id = UInt8(exactly: channel.id) else { return nil }
            ids.append(id)
        }
        guard Set(ids).count == ids.count else { return nil }
        return ids
    }

    // ─────────────────────────────────────────────────────────
    // MARK: - Selection
    // ─────────────────────────────────────────────────────────

    /// Pick the Entertainment Area that safely belongs to a room, or nil.
    ///
    /// Nil is a first-class answer: the caller falls back to REST cleanly. When in doubt we
    /// refuse rather than guess, because guessing means streaming into somebody else's room.
    ///
    /// Eligibility, before any ranking: a config must resolve to at least one real light and
    /// must produce usable channel IDs. An area that cannot actually be streamed may never be
    /// selected, or availability would promise a stream that startup then refuses.
    ///
    /// Configs resolving to the *same* light set are equivalent for this decision (a Hue-app
    /// "screen" area and a ChromaGlow-built "music" area over one room), so they are grouped
    /// and one is chosen deterministically instead of being called ambiguous. Genuinely
    /// different light sets keep the ambiguity rules.
    ///
    /// 1. **Exact** — a group whose light set equals the room's wins outright.
    /// 2. **Contained** — otherwise the unique largest group that is a strict subset of the
    ///    room wins. This is what lets an area cover part of a larger room on purpose. Two
    ///    equally large but different subsets are ambiguous → nil.
    /// 3. **Dominant overlap** — otherwise, and only when at least two groups have *distinct*
    ///    non-empty overlaps with the room, a group wins if its overlap strictly contains
    ///    every other group's. With a single overlapping group there is no contest and
    ///    nothing to compare against, so an area reaching outside the room is refused —
    ///    "strictly contains every other" is never treated as vacuously true.
    ///
    /// Order, area name, and array position are never tie-breakers; the only tie-break is the
    /// stable config ID, inside a group of equivalents. A reordered bridge response therefore
    /// produces the same answer.
    ///
    /// `preferredConfigID` cannot buy its way past room safety: the safe winner is computed
    /// first, and an explicit ID is honoured only if it names one of the winning equivalents.
    /// Anything else returns nil rather than streaming to unrelated lights.
    static func select(
        roomLightIDs: Set<String>,
        configs: [EntertainmentConfig],
        entertainmentToLightMap: [String: String],
        preferredConfigID: String? = nil
    ) -> EntertainmentConfig? {
        guard !roomLightIDs.isEmpty else { return nil }

        // Eligible candidates, deduplicated by config ID (a retried create can
        // otherwise append the same area twice).
        var seenIDs: Set<String> = []
        var groups: [Set<String>: [EntertainmentConfig]] = [:]
        for config in configs {
            guard seenIDs.insert(config.id).inserted else { continue }
            guard validatedChannelIDs(for: config) != nil else { continue }
            let mapped = mappedLightIDs(for: config, entertainmentToLightMap: entertainmentToLightMap)
            guard !mapped.isEmpty else { continue }
            groups[mapped, default: []].append(config)
        }
        guard !groups.isEmpty else { return nil }

        // What the preferred ID actually covers, if it names a config at all. Room
        // safety is judged on its light set, not on its identity.
        let preferredLightIDs: Set<String>? = preferredConfigID.flatMap { id in
            configs.first { $0.id == id }.map {
                mappedLightIDs(for: $0, entertainmentToLightMap: entertainmentToLightMap)
            }
        }

        /// Deterministic choice within a set of equivalents.
        func pick(_ equivalents: [EntertainmentConfig], covering lightIDs: Set<String>) -> EntertainmentConfig? {
            guard let preferredConfigID else { return equivalents.min { $0.id < $1.id } }
            // Honour the explicit ID when it is one of the winning equivalents.
            if let named = equivalents.first(where: { $0.id == preferredConfigID }) { return named }
            // The preferred config covers the same lights but cannot be streamed
            // (no channels, or channel IDs the protocol can't carry). Room safety
            // is unaffected, so fall back to a usable equivalent deterministically.
            if preferredLightIDs == lightIDs { return equivalents.min { $0.id < $1.id } }
            // Anything else names a different set of lights — refuse rather than
            // let an explicit ID stream into another room.
            return nil
        }

        // 1 ── Exact match. Grouping is by light set, so at most one group can qualify.
        if let exact = groups[roomLightIDs] { return pick(exact, covering: roomLightIDs) }

        // 2 ── Largest area fully contained in the room.
        let contained = groups.filter { $0.key.isStrictSubset(of: roomLightIDs) }
        if !contained.isEmpty {
            let widest = contained.keys.map(\.count).max() ?? 0
            let best = contained.filter { $0.key.count == widest }
            guard best.count == 1, let winner = best.first else { return nil }
            return pick(winner.value, covering: winner.key)
        }

        // 3 ── Dominant overlap, and only when there is a real contest to win.
        let overlapping = groups.compactMap { key, equivalents -> (key: Set<String>, overlap: Set<String>, equivalents: [EntertainmentConfig])? in
            let overlap = key.intersection(roomLightIDs)
            return overlap.isEmpty ? nil : (key, overlap, equivalents)
        }
        guard Set(overlapping.map(\.overlap)).count >= 2 else { return nil }

        for candidate in overlapping {
            // Exclude self by group identity, not by overlap equality — two rivals
            // sharing an overlap must cancel each other out, not let one through.
            let rivals = overlapping.filter { $0.key != candidate.key }
            guard !rivals.isEmpty else { continue }
            if rivals.allSatisfy({ candidate.overlap.isStrictSuperset(of: $0.overlap) }) {
                return pick(candidate.equivalents, covering: candidate.key)
            }
        }
        return nil
    }
}
