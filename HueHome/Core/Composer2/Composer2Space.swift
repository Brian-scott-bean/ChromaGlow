// Composer2Space.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Where the lights are, and which lights a behavior layer touches.
// Geometry is rebuilt from the per-slot radial/angular arrays the
// orchestrator already computes (its own slot order), so the engine never
// invents positions: when the arrays are absent, everything degrades to the
// physical index order and says so via `hasSpatialData`.

import Foundation

// MARK: - Slot geometry

struct Composer2SlotGeometry: Equatable {
    let count: Int
    /// Points normalized into the unit square. Empty when positions are unknown.
    let px: [Double]
    let pz: [Double]
    /// i / (n − 1) — the physical order axis and the universal fallback.
    let linearIndex: [Double]
    /// 0…1 distance from the room centroid (0.5 when unknown).
    let radial: [Double]
    /// 0…1 bearing around the centroid (0.5 when unknown).
    let angular: [Double]
    let hasSpatialData: Bool
    /// PCA axis of maximum spread, degrees 0…360 (0 when unknown).
    let principalAngleDegrees: Double
    /// Light id per slot when the caller could resolve one (UI layouts).
    let lightIDs: [String]?

    static func linear(count: Int, lightIDs: [String]? = nil) -> Composer2SlotGeometry {
        let n = Swift.max(0, count)
        let idx = (0..<n).map { n > 1 ? Double($0) / Double(n - 1) : 0.5 }
        return Composer2SlotGeometry(
            count: n, px: [], pz: [], linearIndex: idx,
            radial: Array(repeating: 0.5, count: n),
            angular: Array(repeating: 0.5, count: n),
            hasSpatialData: false, principalAngleDegrees: 0,
            lightIDs: lightIDs?.count == n ? lightIDs : nil)
    }

    /// Rebuild 2D points from the orchestrator's normalized polar arrays.
    init(radial: [Double], angular: [Double], lightIDs: [String]? = nil) {
        let n = Swift.min(radial.count, angular.count)
        var points: [(x: Double, z: Double)] = []
        points.reserveCapacity(n)
        var spread = 0.0
        for i in 0..<n {
            let r = Composer2Math.clamp01(radial[i])
            let theta = (Composer2Math.clamp01(angular[i]) - 0.5) * 2 * .pi
            points.append((r * cos(theta), r * sin(theta)))
            spread = Swift.max(spread, r)
        }
        if n > 1 && spread > 0.001 {
            self.init(points: points, lightIDs: lightIDs)
        } else {
            self = .linear(count: n, lightIDs: lightIDs)
        }
    }

    /// Build from explicit 2D points (UI layouts, tests).
    init(points: [(x: Double, z: Double)], lightIDs: [String]? = nil) {
        let n = points.count
        guard n > 1 else {
            self = .linear(count: n, lightIDs: lightIDs)
            return
        }
        let finite = points.map { (x: $0.x.isFinite ? $0.x : 0, z: $0.z.isFinite ? $0.z : 0) }
        let cx = finite.reduce(0.0) { $0 + $1.x } / Double(n)
        let cz = finite.reduce(0.0) { $0 + $1.z } / Double(n)
        let dists = finite.map { hypot($0.x - cx, $0.z - cz) }
        let maxDist = dists.max() ?? 0
        guard maxDist > 0.001 else {
            self = .linear(count: n, lightIDs: lightIDs)
            return
        }
        let radial = dists.map { $0 / maxDist }
        let angular = finite.map { (atan2($0.z - cz, $0.x - cx) / (2 * .pi)) + 0.5 }

        // Normalize into the unit square, keeping the aspect ratio.
        let minX = finite.map(\.x).min() ?? 0, maxX = finite.map(\.x).max() ?? 1
        let minZ = finite.map(\.z).min() ?? 0, maxZ = finite.map(\.z).max() ?? 1
        let extent = Swift.max(maxX - minX, maxZ - minZ, 1e-6)
        let offX = (extent - (maxX - minX)) / 2
        let offZ = (extent - (maxZ - minZ)) / 2
        let px = finite.map { ($0.x - minX + offX) / extent }
        let pz = finite.map { ($0.z - minZ + offZ) / extent }

        // Principal axis — the same 2×2 covariance formula the legacy engine uses.
        var cxx = 0.0, cxz = 0.0, czz = 0.0
        for p in finite {
            let dx = p.x - cx, dz = p.z - cz
            cxx += dx * dx; cxz += dx * dz; czz += dz * dz
        }
        var degrees = 0.5 * atan2(2.0 * cxz, cxx - czz) * 180.0 / .pi
        if degrees < 0 { degrees += 360 }

        self.init(count: n, px: px, pz: pz,
                  linearIndex: (0..<n).map { Double($0) / Double(n - 1) },
                  radial: radial, angular: angular,
                  hasSpatialData: true, principalAngleDegrees: degrees,
                  lightIDs: lightIDs?.count == n ? lightIDs : nil)
    }

    private init(count: Int, px: [Double], pz: [Double], linearIndex: [Double],
                 radial: [Double], angular: [Double], hasSpatialData: Bool,
                 principalAngleDegrees: Double, lightIDs: [String]?) {
        self.count = count
        self.px = px
        self.pz = pz
        self.linearIndex = linearIndex
        self.radial = radial
        self.angular = angular
        self.hasSpatialData = hasSpatialData
        self.principalAngleDegrees = principalAngleDegrees
        self.lightIDs = lightIDs
    }

    func withLightIDs(_ ids: [String]?) -> Composer2SlotGeometry {
        Composer2SlotGeometry(count: count, px: px, pz: pz, linearIndex: linearIndex,
                              radial: radial, angular: angular, hasSpatialData: hasSpatialData,
                              principalAngleDegrees: principalAngleDegrees,
                              lightIDs: ids?.count == count ? ids : nil)
    }

    /// Per-slot 0…1 position along an axis. Without spatial data every axis
    /// is the physical index order.
    func projection(kind: Composer2Motion.AxisKind, angleDegrees: Double) -> [Double] {
        guard hasSpatialData, count > 1 else { return linearIndex }
        switch kind {
        case .radial:
            return radial
        case .angular:
            return angular
        case .principal, .angle:
            let degrees = kind == .principal ? principalAngleDegrees : angleDegrees
            let rad = (degrees.isFinite ? degrees : 0) * .pi / 180
            let dx = cos(rad), dz = sin(rad)
            let projections = (0..<count).map { px[$0] * dx + pz[$0] * dz }
            return Composer2SlotGeometry.normalize(projections)
        }
    }

    /// Point for slot `i` in the unit square (nil without spatial data).
    func point(_ i: Int) -> (x: Double, z: Double)? {
        guard hasSpatialData, i >= 0, i < px.count else { return nil }
        return (px[i], pz[i])
    }

    static func normalize(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        let range = hi - lo
        guard range > 0.001 else { return values.map { _ in 0.5 } }
        return values.map { ($0 - lo) / range }
    }
}

// MARK: - Floor plan

/// One mapping from bridge positions to the unit-square room picture, shared
/// by every Composer 2 layout AND the live geometry — so what the hero shows
/// and what the lights do can never be mirrored against each other.
///
/// Hue Entertainment positions are x = left → right, y = front → back and
/// z = floor → ceiling, each −1…1. The floor plan is therefore (x, y). Areas
/// whose lights all sit on one front/back line (the ones ChromaGlow's own
/// area builder writes) carry no depth in y; there, height is the only
/// second dimension the bridge knows, so it stands in.
enum Composer2FloorPlan {
    static func depthUsesHeight(_ positions: [(x: Double, y: Double, z: Double)]) -> Bool {
        let ys = positions.map(\.y).filter(\.isFinite)
        let zs = positions.map(\.z).filter(\.isFinite)
        let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
        let zSpread = (zs.max() ?? 0) - (zs.min() ?? 0)
        return ySpread < 0.05 && zSpread >= 0.05
    }

    /// Unit-square point: x left → right, z (screen depth) back/top = 0.
    static func point(x: Double, y: Double, z: Double, depthUsesHeight: Bool) -> (x: Double, z: Double) {
        let depth = depthUsesHeight ? z : y
        return (x: Composer2Math.clamp01(((x.isFinite ? x : 0) + 1) / 2),
                z: Composer2Math.clamp01((1 - (depth.isFinite ? depth : 0)) / 2))
    }
}

// MARK: - Layer mask

/// Which lights a layer drives, as a 0…1 weight per slot.
struct Composer2LayerMask: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case wholeRoom = "whole_room"
        case slots
        case lightIDs = "light_ids"
        case randomSubset = "random_subset"
        case region
    }

    var kind: Kind = .wholeRoom
    var slots: [Int] = []
    var lightIDs: [String] = []
    /// Random subset: fraction of lights (used when `count` is nil).
    var fraction: Double = 0.5
    var count: Int? = nil
    /// Region in the unit square (with the physical index as X when no positions exist).
    var regionX0: Double = 0
    var regionZ0: Double = 0
    var regionX1: Double = 1
    var regionZ1: Double = 1
    var feather: Double = 0
    var invert: Bool = false

    init(kind: Kind = .wholeRoom, slots: [Int] = [], lightIDs: [String] = [],
         fraction: Double = 0.5, count: Int? = nil,
         regionX0: Double = 0, regionZ0: Double = 0, regionX1: Double = 1, regionZ1: Double = 1,
         feather: Double = 0, invert: Bool = false) {
        self.kind = kind
        self.slots = slots
        self.lightIDs = lightIDs
        self.fraction = fraction
        self.count = count
        self.regionX0 = regionX0
        self.regionZ0 = regionZ0
        self.regionX1 = regionX1
        self.regionZ1 = regionZ1
        self.feather = feather
        self.invert = invert
    }

    enum CodingKeys: String, CodingKey {
        case kind, slots, lightIDs, fraction, count, regionX0, regionZ0, regionX1, regionZ1, feather, invert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2LayerMask()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? d.kind
        slots = (try? c.decode([Int].self, forKey: .slots)) ?? d.slots
        lightIDs = (try? c.decode([String].self, forKey: .lightIDs)) ?? d.lightIDs
        fraction = (try? c.decode(Double.self, forKey: .fraction)) ?? d.fraction
        count = try? c.decode(Int.self, forKey: .count)
        regionX0 = (try? c.decode(Double.self, forKey: .regionX0)) ?? d.regionX0
        regionZ0 = (try? c.decode(Double.self, forKey: .regionZ0)) ?? d.regionZ0
        regionX1 = (try? c.decode(Double.self, forKey: .regionX1)) ?? d.regionX1
        regionZ1 = (try? c.decode(Double.self, forKey: .regionZ1)) ?? d.regionZ1
        feather = (try? c.decode(Double.self, forKey: .feather)) ?? d.feather
        invert = (try? c.decode(Bool.self, forKey: .invert)) ?? d.invert
    }

    static let wholeRoom = Composer2LayerMask()

    static func randomSubset(fraction: Double) -> Composer2LayerMask {
        Composer2LayerMask(kind: .randomSubset, fraction: fraction)
    }

    static func randomCount(_ count: Int) -> Composer2LayerMask {
        Composer2LayerMask(kind: .randomSubset, count: count)
    }

    static func slots(_ slots: [Int]) -> Composer2LayerMask {
        Composer2LayerMask(kind: .slots, slots: slots)
    }

    /// Human-readable count of lights the mask keeps, given `total` lights.
    func selectedCount(total: Int) -> Int {
        guard total > 0 else { return 0 }
        let base: Int
        switch kind {
        case .wholeRoom: base = total
        case .slots: base = Set(slots.filter { $0 >= 0 && $0 < total }).count
        case .lightIDs: base = lightIDs.isEmpty ? total : Swift.min(total, lightIDs.count)
        case .randomSubset: base = Composer2LayerMask.subsetCount(total: total, fraction: fraction, count: count)
        case .region: base = total
        }
        return invert ? total - base : base
    }

    static func subsetCount(total: Int, fraction: Double, count: Int?) -> Int {
        if let count { return Swift.max(0, Swift.min(total, count)) }
        let f = Composer2Math.clamp01(fraction)
        return Swift.max(0, Swift.min(total, Int((f * Double(total)).rounded(.toNearestOrEven))))
    }

    /// 0…1 weight per slot. Deterministic for a given (mask, geometry, seed).
    func weights(geometry: Composer2SlotGeometry, seed: UInt64) -> [Double] {
        let n = geometry.count
        guard n > 0 else { return [] }
        var w = Array(repeating: 0.0, count: n)
        switch kind {
        case .wholeRoom:
            w = Array(repeating: 1.0, count: n)

        case .slots:
            for s in slots where s >= 0 && s < n { w[s] = 1 }

        case .lightIDs:
            if lightIDs.isEmpty || geometry.lightIDs == nil {
                // Unknown identities → the whole room, never a silent no-op.
                w = Array(repeating: 1.0, count: n)
            } else {
                let wanted = Set(lightIDs)
                for (i, id) in (geometry.lightIDs ?? []).enumerated() where wanted.contains(id) {
                    w[i] = 1
                }
            }

        case .randomSubset:
            let k = Composer2LayerMask.subsetCount(total: n, fraction: fraction, count: count)
            let ranked = (0..<n).sorted {
                let a = Composer2Hash.unit(seed, $0, 0, salt: 0x3A5C)
                let b = Composer2Hash.unit(seed, $1, 0, salt: 0x3A5C)
                return a < b || (a == b && $0 < $1)
            }
            for i in ranked.prefix(k) { w[i] = 1 }

        case .region:
            let xr = Composer2Math.orderedRange(regionX0, regionX1)
            let zr = Composer2Math.orderedRange(regionZ0, regionZ1)
            let f = Composer2Math.clamp01(feather) * 0.5
            for i in 0..<n {
                let x: Double, z: Double
                if let p = geometry.point(i) {
                    x = p.x; z = p.z
                } else {
                    x = geometry.linearIndex[i]; z = 0.5
                }
                let inX = Composer2LayerMask.softInside(x, lo: xr.lo, hi: xr.hi, feather: f)
                let inZ = Composer2LayerMask.softInside(z, lo: zr.lo, hi: zr.hi, feather: f)
                w[i] = inX * inZ
            }
        }
        if invert { w = w.map { 1 - $0 } }
        return w
    }

    private static func softInside(_ v: Double, lo: Double, hi: Double, feather: Double) -> Double {
        guard hi >= lo else { return 0 }
        if feather <= 0 { return (v >= lo && v <= hi) ? 1 : 0 }
        let rise = Composer2Math.smoothstep((v - (lo - feather)) / (2 * feather))
        let fall = 1 - Composer2Math.smoothstep((v - (hi - feather)) / (2 * feather))
        return Swift.min(rise, fall)
    }
}
