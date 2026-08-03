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
//  • EVERY light in the room gets an entry, and at least one channel.
//    A gradient-capable light expands to `min(points_capable, 5)` channels;
//    5 is the real CLIP v2 `gradient.points` ceiling (HueAPIClient+Gradient).
//
// Composer 2 packet 5 removed a global `channelBudget = 20` from this file.
// It was never a protocol limit: its own comment said it existed only to
// "match the render loop's channel cap", and that cap was itself an accident
// of `LightFrame.channelID` being `UInt8`. It did two kinds of damage —
// `prefix(20)` dropped lights 21+ from the map entirely (they then received
// no composition write at all, silently), and the reserve-one-per-remaining
// -light rule starved strips in ordinary rooms: 18 bulbs plus a 5-point strip
// left the strip 2 points, and at 19 bulbs it fell to 1, `hasGradient` went
// false, the map returned nil and the strip rendered one flat colour with no
// indication. Neither behaviour reflected what a bridge or a strip can do.

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

    /// Builds the map in light order. Returns nil when no light gets ≥2
    /// channels — callers keep the existing flat path untouched.
    ///
    /// Every light in `orderedLightIDs` gets exactly one entry: the map is a
    /// complete description of the room, never a truncated one. Total channel
    /// count is whatever that sums to — the REST scheduler bounds how many
    /// OPERATIONS one sweep dispatches (packet 5 rolling subsets), which is a
    /// separate concern from how many channels the room renders.
    static func build(orderedLightIDs: [String], lights: [HueLight]) -> GradientChannelMap? {
        let byID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [Entry] = []
        var cursor = 0
        var hasGradient = false

        for id in orderedLightIDs {
            // A strip expands to its own reported capability, capped at the
            // real CLIP v2 gradient.points ceiling. No global budget: one
            // light's segments can no longer starve another light's channel.
            var count = 1
            let capable = byID[id]?.gradient?.points_capable ?? 0
            if capable >= 2 {
                count = min(capable, maxPointsPerStrip)
            }
            entries.append(Entry(lightID: id, channelStart: cursor, channelCount: count))
            if count > 1 { hasGradient = true }
            cursor += count
        }

        return hasGradient ? GradientChannelMap(entries: entries) : nil
    }
}
