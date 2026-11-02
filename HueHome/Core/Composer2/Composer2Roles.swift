// Composer2Roles.swift
// ChromaGlow — Core/Composer2 ("the room is the band", step 3: build 917)
//
// Which lights are LOW (floor lamps — the kick and the bass), MIDDLE (eye
// height — the held wash) and HIGH (ceiling, pendants — snare and hats), as
// lighting designers split a room. Hue stores each Entertainment light's
// height as z (−1 floor … +1 ceiling), but only when someone set it in the
// Hue app's area editor — ChromaGlow's own area builder writes z = 0 — and
// Composer 2 never read it. So a role comes from, in order:
//   1. what the user told ChromaGlow (Play Along → Light heights), per light;
//   2. the bridge's z, when the area has any height at all (z spread ≥ 0.05);
//   3. the product type (floor lamps low, ceiling and pendant lights high);
//   4. otherwise middle.
// Answers are kept on the phone (per light id: a light's height is a fact
// about the room, not about one area). Writing them back to the bridge as z
// (so other apps see them) is NOT done: it rewrites the area's positions and
// needs a real-bridge test first.
//
// THREADING CONTRACT: the answer store is lock-guarded; the render thread
// reads `version` every frame and the answers only when it changed.

import Foundation

enum Composer2LightRole: String, Codable, CaseIterable, Sendable {
    case low, middle, high

    var title: String {
        switch self {
        case .low: return "Low"
        case .middle: return "Middle"
        case .high: return "High"
        }
    }
}

enum Composer2LightRoles {
    /// Where a light's role came from.
    enum Source: Equatable, Sendable { case answer, bridge, product, unknown }

    static let defaultsKey = "playAlong.lightHeights"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Composer2LightRole]?
    nonisolated(unsafe) private static var _version: UInt64 = 0
    nonisolated(unsafe) private static var defaults: UserDefaults = .standard

    /// Bumped on every answer: renderers re-resolve when it moves.
    static var version: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    /// The user's answers, per light id.
    static func answers() -> [String: Composer2LightRole] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    static func setAnswer(_ role: Composer2LightRole?, lightID: String) {
        lock.lock()
        var all = loadLocked()
        all[lightID] = role
        cache = all
        _version &+= 1
        let store = defaults
        lock.unlock()
        store.set(all.mapValues(\.rawValue), forKey: defaultsKey)
    }

    /// Tests: a private store (pass nil to go back to the standard one).
    static func useDefaults(_ store: UserDefaults?) {
        lock.lock()
        defaults = store ?? .standard
        cache = nil
        _version &+= 1
        lock.unlock()
    }

    private static func loadLocked() -> [String: Composer2LightRole] {
        if let cache { return cache }
        let raw = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let loaded = raw.compactMapValues(Composer2LightRole.init(rawValue:))
        cache = loaded
        return loaded
    }

    // MARK: - Resolving

    /// Each slot's role and where it came from. `z` = the bridge height per
    /// slot when the slot is an Entertainment channel (nil otherwise — Room
    /// mode positions are a floor plan, not heights).
    static func resolve(lightIDs: [String?], z: [Double?], archetypes: [String?],
                        answers: [String: Composer2LightRole]) -> [(role: Composer2LightRole, source: Source)] {
        let n = lightIDs.count
        let heights = (0..<n).compactMap { $0 < z.count ? z[$0] : nil }.filter(\.isFinite)
        let bridgeKnows = ((heights.max() ?? 0) - (heights.min() ?? 0)) >= 0.05
        return (0..<n).map { i in
            if let id = lightIDs[i], let role = answers[id] { return (role, .answer) }
            if bridgeKnows, i < z.count, let h = z[i], h.isFinite {
                return (h < -1.0 / 3 ? .low : h > 1.0 / 3 ? .high : .middle, .bridge)
            }
            if let role = productRole(i < archetypes.count ? archetypes[i] : nil) { return (role, .product) }
            return (.middle, .unknown)
        }
    }

    /// Roles for render slots (the live path).
    static func resolve(_ slots: [CompositionRenderSlot],
                        answers: [String: Composer2LightRole]) -> [(role: Composer2LightRole, source: Source)] {
        resolve(lightIDs: slots.map(\.lightID),
                z: slots.map { $0.channelID != nil ? $0.position?.z : nil },
                archetypes: slots.map(\.archetype),
                answers: answers)
    }

    /// A Hue product type's usual height, when it has one.
    static func productRole(_ archetype: String?) -> Composer2LightRole? {
        let a = (archetype ?? "").lowercased()
        guard !a.isEmpty else { return nil }
        if a.hasPrefix("floor") || a.contains("recessed_floor") || a.contains("ground") || a.contains("bollard")
            || a.contains("bloom") {
            return .low
        }
        if a.contains("ceiling") || a.contains("pendant") || a.contains("centris") || a.contains("single_spot")
            || a.contains("double_spot") {
            return .high
        }
        if a.contains("table") || a.contains("wall") || a.contains("desk") { return .middle }
        return nil
    }

    /// True when the room has both a low and a high light — what the band
    /// needs to split the drums across the room.
    static func canSplit(_ roles: [Composer2LightRole]) -> Bool {
        roles.contains(.low) && roles.contains(.high)
    }
}
