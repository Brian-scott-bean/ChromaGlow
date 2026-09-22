// Composer2SlotLayout.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The on-screen picture of the room: one slot per render position, with a
// light name and — when the bridge told us — a real position. Three honest
// sources: the Entertainment Area (real positions, streaming order), the
// room's light order (Room mode, positions unknown) and a semantic estimate
// for demo homes. Estimated layouts are always labelled as such.

import Foundation

struct Composer2SlotLayout: Equatable {
    struct Slot: Equatable, Identifiable {
        let index: Int
        let lightID: String?
        let name: String
        let archetype: String?
        /// Position in the unit square (0…1), or nil when unknown.
        let x: Double?
        let z: Double?
        /// What the light can reproduce (nil = not resolved).
        var capability: CompositionSlotCapability? = nil
        /// Segment within a multi-channel light, 1-based, with its count.
        var segment: (index: Int, count: Int)? = nil

        var id: Int { index }
        var hasPosition: Bool { x != nil && z != nil }
        var isColour: Bool { capability == nil || capability == .color }

        static func == (lhs: Slot, rhs: Slot) -> Bool {
            lhs.index == rhs.index && lhs.lightID == rhs.lightID && lhs.name == rhs.name
                && lhs.archetype == rhs.archetype && lhs.x == rhs.x && lhs.z == rhs.z
                && lhs.capability == rhs.capability
                && lhs.segment?.index == rhs.segment?.index && lhs.segment?.count == rhs.segment?.count
        }
    }

    enum Source: Equatable {
        case streaming(areaName: String)
        case roomMode
        case estimated
        case empty
    }

    let slots: [Slot]
    let source: Source
    /// True when the drawn positions are a layout guess, not bridge data.
    let positionsAreEstimated: Bool

    static let empty = Composer2SlotLayout(slots: [], source: .empty, positionsAreEstimated: true)

    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }

    /// Distinct physical lights (a gradient strip may own several slots).
    var lightCount: Int {
        var seen = Set<String>()
        var anonymous = 0
        for s in slots {
            if let id = s.lightID { seen.insert(id) } else { anonymous += 1 }
        }
        return seen.count + anonymous
    }

    var lightIDs: [String]? {
        let ids = slots.compactMap(\.lightID)
        return ids.count == slots.count ? ids : nil
    }

    /// Engine geometry for previews. Estimated positions still drive the
    /// on-screen motion so the picture reads as a room; the live loop
    /// replaces this with the orchestrator's own geometry.
    var geometry: Composer2SlotGeometry {
        guard !slots.isEmpty else { return .linear(count: 0) }
        if slots.allSatisfy(\.hasPosition) {
            return Composer2SlotGeometry(points: slots.map { ($0.x ?? 0.5, $0.z ?? 0.5) }, lightIDs: lightIDs)
        }
        return .linear(count: slots.count, lightIDs: lightIDs)
    }

    /// Lights that cannot show colour (they follow brightness, and warmth where they can).
    var whiteOnlyCount: Int {
        var seen = Set<String>()
        var count = 0
        for s in slots where !s.isColour {
            if let id = s.lightID { if seen.insert(id).inserted { count += 1 } } else { count += 1 }
        }
        return count
    }

    // MARK: Builders

    /// Composer 2.1: the layout from the orchestrator's exact slots — the
    /// truth for labels, segments and positions once a session is live.
    static func resolved(slots: [CompositionRenderSlot], lights: [LightDisplayItem],
                         areaName: String?) -> Composer2SlotLayout {
        guard !slots.isEmpty else { return .empty }
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let streaming = slots.contains { $0.channelID != nil }
        let allPositioned = slots.allSatisfy { $0.position != nil }
        let estimated = semanticPositions(count: slots.count, archetypes: slots.map { $0.lightID.flatMap { byID[$0]?.archetype } })
        // Room-mode segments share one position; fan them a little so nodes
        // stay tappable. That fan is presentation, so the layout stays honest
        // by reporting positions as estimated whenever it applies.
        let fannedSegments = !streaming && slots.contains { $0.isSegment }
        let usesHeight = Composer2FloorPlan.depthUsesHeight(
            slots.compactMap(\.position).map { (x: $0.x, y: $0.y, z: $0.z) })
        var out: [Slot] = []
        for s in slots {
            var name = s.lightID.flatMap { byID[$0]?.name } ?? "Light \(s.index + 1)"
            if s.isSegment { name += " · \(s.segmentIndex + 1)/\(s.segmentCount)" }
            let x: Double?, z: Double?
            if let p = s.position {
                let point = Composer2FloorPlan.point(x: p.x, y: p.y, z: p.z, depthUsesHeight: usesHeight)
                var px = point.x
                let pz = point.z
                if fannedSegments, s.isSegment {
                    px = Composer2Math.clamp01(px + (Double(s.segmentIndex) - Double(s.segmentCount - 1) / 2) * 0.03)
                }
                x = px; z = pz
            } else {
                x = estimated[s.index].x; z = estimated[s.index].z
            }
            out.append(Slot(index: s.index, lightID: s.lightID, name: name,
                            archetype: s.lightID.flatMap { byID[$0]?.archetype }, x: x, z: z,
                            capability: s.capability,
                            segment: s.isSegment ? (s.segmentIndex + 1, s.segmentCount) : nil))
        }
        let source: Source = streaming ? .streaming(areaName: areaName ?? "Entertainment Area") : .roomMode
        return Composer2SlotLayout(slots: out, source: source,
                                   positionsAreEstimated: !allPositioned || fannedSegments)
    }

    /// Streaming order: one slot per Entertainment channel, in the bridge's
    /// channel order, with the channel's real position.
    static func streaming(config: EntertainmentConfig, membership: [String: String],
                          lights: [LightDisplayItem]) -> Composer2SlotLayout {
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        let resolved: [(lightID: String?, x: Double, y: Double, z: Double)] = config.channels.map { channel in
            let lightID = channel.lightServiceIDs.compactMap { membership[$0] }.first
            if let lightID { counts[lightID, default: 0] += 1 }
            return (lightID, channel.position.x, channel.position.y, channel.position.z)
        }
        // Map bridge coordinates (−1…1) into the unit square — the shared
        // floor plan, identical to the live geometry.
        let usesHeight = Composer2FloorPlan.depthUsesHeight(
            config.channels.map { (x: $0.position.x, y: $0.position.y, z: $0.position.z) })
        var seen: [String: Int] = [:]
        var slots: [Slot] = []
        for (i, r) in resolved.enumerated() {
            var name = r.lightID.flatMap { byID[$0]?.name } ?? "Light \(i + 1)"
            if let id = r.lightID, let total = counts[id], total > 1 {
                seen[id, default: 0] += 1
                name += " · \(seen[id] ?? 1)/\(total)"
            }
            let point = Composer2FloorPlan.point(x: r.x, y: r.y, z: r.z, depthUsesHeight: usesHeight)
            slots.append(Slot(index: i, lightID: r.lightID, name: name,
                              archetype: r.lightID.flatMap { byID[$0]?.archetype },
                              x: point.x,
                              z: point.z,
                              capability: r.lightID.flatMap { byID[$0] }.map(Self.capability)))
        }
        return Composer2SlotLayout(slots: slots, source: .streaming(areaName: config.name), positionsAreEstimated: false)
    }

    /// Room mode: the resolver's light order, gradient strips expanded, and
    /// positions estimated from what each light is.
    static func roomMode(room: RoomDisplayItem, rawLights: [HueLight], lights: [LightDisplayItem]) -> Composer2SlotLayout {
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = CompositionLightResolver.resolveLightIDs(childResourceRefs: room.childResourceRefs, lights: rawLights)
        if ids.isEmpty { ids = lights.map(\.id) }
        guard !ids.isEmpty else { return .empty }
        let map = GradientChannelMap.build(orderedLightIDs: ids, lights: rawLights)
        var names: [(lightID: String, name: String, archetype: String?)] = []
        for id in ids {
            let item = byID[id]
            let base = item?.name ?? rawLights.first { $0.id == id }?.metadata.name ?? "Light \(names.count + 1)"
            let archetype = item?.archetype ?? rawLights.first { $0.id == id }?.metadata.archetype
            let channels = map?.entries.first { $0.lightID == id }?.channelCount ?? 1
            if channels > 1 {
                for k in 0..<channels { names.append((id, "\(base) · \(k + 1)/\(channels)", archetype)) }
            } else {
                names.append((id, base, archetype))
            }
        }
        let estimated = semanticPositions(count: names.count, archetypes: names.map(\.archetype))
        let slots = names.enumerated().map { i, n in
            Slot(index: i, lightID: n.lightID, name: n.name, archetype: n.archetype,
                 x: estimated[i].x, z: estimated[i].z,
                 capability: byID[n.lightID].map(Self.capability))
        }
        return Composer2SlotLayout(slots: slots, source: .roomMode, positionsAreEstimated: true)
    }

    /// Demo homes and rooms without bridge data: a pleasant, deterministic
    /// arrangement by what each light is.
    static func estimated(lights: [LightDisplayItem]) -> Composer2SlotLayout {
        guard !lights.isEmpty else { return .empty }
        let positions = semanticPositions(count: lights.count, archetypes: lights.map(\.archetype))
        let slots = lights.enumerated().map { i, l in
            Slot(index: i, lightID: l.id, name: l.name, archetype: l.archetype,
                 x: positions[i].x, z: positions[i].z, capability: capability(l))
        }
        return Composer2SlotLayout(slots: slots, source: .estimated, positionsAreEstimated: true)
    }

    /// Capability from the UI light model (colour → tunable white → dimmable).
    static func capability(_ light: LightDisplayItem) -> CompositionSlotCapability {
        if light.supportsColor { return .color }
        if light.supportsColorTemp { return .tunableWhite }
        return .dimmable
    }

    // MARK: Semantic layout

    private enum Family { case strip, lamp, ceiling, other }

    private static func family(_ archetype: String?) -> Family {
        let a = (archetype ?? "").lowercased()
        if a.contains("strip") || a.contains("gradient") || a.contains("christmas") || a.contains("string") { return .strip }
        if a.contains("shade") || a.contains("lantern") || a.contains("lamp") || a.contains("bollard") { return .lamp }
        if a.contains("ceiling") || a.contains("pendant") || a.contains("recessed") || a.contains("spot")
            || a.contains("sultan") || a.contains("flood") || a.contains("candle") || a.contains("bulb") { return .ceiling }
        return .other
    }

    /// Stable per index: the same room lays out the same way every time.
    static func semanticPositions(count: Int, archetypes: [String?]) -> [(x: Double, z: Double)] {
        guard count > 0 else { return [] }
        var strips: [Int] = [], lamps: [Int] = [], ceilings: [Int] = [], others: [Int] = []
        for i in 0..<count {
            switch family(i < archetypes.count ? archetypes[i] : nil) {
            case .strip: strips.append(i)
            case .lamp: lamps.append(i)
            case .ceiling: ceilings.append(i)
            case .other: others.append(i)
            }
        }
        var out = Array(repeating: (x: 0.5, z: 0.5), count: count)
        // Strips along the back wall.
        for (k, i) in strips.enumerated() {
            let n = Double(strips.count)
            out[i] = (x: n > 1 ? 0.15 + 0.7 * Double(k) / (n - 1) : 0.5, z: 0.12)
        }
        // Lamps alternate left / right, front to back.
        for (k, i) in lamps.enumerated() {
            let n = Double(lamps.count)
            let side = k % 2 == 0 ? 0.12 : 0.88
            out[i] = (x: side, z: n > 1 ? 0.35 + 0.5 * Double(k) / (n - 1) : 0.6)
        }
        // Ceiling lights in a centred arc.
        for (k, i) in ceilings.enumerated() {
            let n = Double(ceilings.count)
            let t = n > 1 ? Double(k) / (n - 1) : 0.5
            out[i] = (x: 0.25 + 0.5 * t, z: 0.45 - 0.12 * sin(.pi * t))
        }
        // Everything else on a golden-angle ring.
        for (k, i) in others.enumerated() {
            let angle = Double(k) * 2.399963 + 0.7
            let radius = 0.22 + 0.16 * Composer2Math.frac(Double(k) * 0.618)
            out[i] = (x: Composer2Math.clamp01(0.5 + radius * cos(angle)),
                      z: Composer2Math.clamp01(0.55 + radius * 0.7 * sin(angle)))
        }
        return out
    }
}
