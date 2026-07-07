// GradientChannelMap.swift
// ChromaGlow — Round 3 Phase F (full Hue power; highest-risk, lands last)
//
// Pure mapping that lets compositions render ALONG gradient strips over
// plain REST: a gradient-capable light (Play gradient strip, Signe) stops
// being one flat channel and becomes up to 5 virtual render channels — the
// REST scheduler then writes those frames as ONE gradient.points PUT.
//
// Rules:
//  • nil map = no gradient light in the room → the flat per-light path
//    stays byte-identical to today.
//  • Global channel budget 20 (matches the render loop's channel cap).
//    Every light is guaranteed its 1 channel first; strips absorb the
//    remaining budget (trimmed, never starving a later light).

import Foundation

struct GradientChannelMap: Equatable {

    struct Entry: Equatable {
        let lightID: String
        let channelStart: Int
        let channelCount: Int                 // 1 = flat; 2…5 = gradient points

        var isGradient: Bool { channelCount > 1 }
        var channelRange: Range<Int> { channelStart ..< (channelStart + channelCount) }
    }

    let entries: [Entry]

    var totalChannels: Int {
        entries.last.map { $0.channelStart + $0.channelCount } ?? 0
    }

    static let maxPointsPerStrip = 5
    static let channelBudget = 20

    /// Builds the map in light order. Returns nil when no light gets ≥2
    /// channels — callers keep the existing flat path untouched.
    static func build(orderedLightIDs: [String], lights: [HueLight]) -> GradientChannelMap? {
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Budget can't cover more than 20 flat lights — same cap as today.
        let ids = Array(orderedLightIDs.prefix(channelBudget))

        var entries: [Entry] = []
        var cursor = 0
        var hasGradient = false

        for (index, id) in ids.enumerated() {
            let lightsAfterThis = ids.count - index - 1
            // Reserve one channel for every remaining light before letting
            // this one expand.
            let expandable = channelBudget - cursor - lightsAfterThis
            var count = 1
            let capable = byID[id]?.gradient?.points_capable ?? 0
            if capable >= 2 {
                let want = min(capable, maxPointsPerStrip)
                if expandable >= 2 {
                    count = min(want, expandable)
                }
            }
            entries.append(Entry(lightID: id, channelStart: cursor, channelCount: count))
            if count > 1 { hasGradient = true }
            cursor += count
        }

        return hasGradient ? GradientChannelMap(entries: entries) : nil
    }
}
