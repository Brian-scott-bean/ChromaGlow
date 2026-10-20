// OutputLatencyModel.swift
// ChromaGlow — Core/Audio (Play Along P2)
//
// How far ahead of "now" a light frame has to be rendered so the room SHOWS
// it when the room HEARS it. Nothing compensated for this before: frames were
// rendered for the instant they were computed, and every one of them reached
// the bulbs one bridge-and-radio delay late — on top of the beat grid's own
// error. Render loops now evaluate musical time at `hostNow + lead`.
//
//   lead = light latency (transport) + half the bridge's update period
//          − the user's per-bridge "Light timing" offset
//
// The offset reads the way the slider does: negative = lights earlier, so it
// renders further ahead. (It used to be added, and "earlier" made the lights
// later.)
//
// The half-period centres the frame quantisation (±20 ms at the bridge's
// 25 Hz Zigbee rate) instead of always landing late. The latencies are
// starting points: Signify publishes none, the community measures ~80 ms
// video-to-light for Entertainment; docs/ios/play-along/README.md §8.1
// (slo-mo of a bulb against a click) replaces them with a measured number.
// REST is not beat-accurate (100 ms per command, 200 ms transitions) — its
// lead only centres Play Along's bar-length fades.

import Foundation

enum OutputLatencyModel {
    enum Transport: Sendable, Equatable {
        case entertainment
        case rest
    }

    /// Frame leaves the app → the bulb shows it (Entertainment).
    static let entertainmentLatency = 0.080
    /// The bridge drives bulbs over Zigbee at 25 Hz.
    static let entertainmentBridgePeriod = 0.040
    /// Room-mode writes: mailbox + command gate + HTTP + half a 200 ms fade.
    static let restLatency = 0.250
    /// The user's "Light timing" range, seconds (negative = lights earlier,
    /// a longer lead). Most of the room is on the early side: the 100 ms
    /// starting lead is a guess, and a slow bridge trails it.
    static let userOffsetRange: ClosedRange<Double> = -0.300...0.150

    /// Seconds to render ahead on `transport` for the bridge `bridgeID`.
    static func lead(transport: Transport, bridgeID: String?) -> Double {
        let base: Double
        switch transport {
        case .entertainment: base = entertainmentLatency + entertainmentBridgePeriod / 2
        case .rest: base = restLatency
        }
        return max(0, base - userOffset(bridgeID: bridgeID))
    }

    // MARK: - The user's per-bridge offset

    static func defaultsKey(bridgeID: String) -> String { "playAlong.lightTimingMs.\(bridgeID)" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Double] = [:]

    /// Seconds. Cached after the first read: render loops ask every frame.
    static func userOffset(bridgeID: String?, defaults: UserDefaults = .standard) -> Double {
        guard let bridgeID, !bridgeID.isEmpty else { return 0 }
        lock.lock()
        if let cached = cache[bridgeID] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let ms = defaults.object(forKey: defaultsKey(bridgeID: bridgeID)) as? Double ?? 0
        let seconds = clamped(ms / 1000)
        lock.lock()
        cache[bridgeID] = seconds
        lock.unlock()
        return seconds
    }

    /// Store the user's offset (seconds) for `bridgeID`; render loops see it
    /// on their next frame.
    static func setUserOffset(_ seconds: Double, bridgeID: String, defaults: UserDefaults = .standard) {
        let value = clamped(seconds)
        defaults.set(value * 1000, forKey: defaultsKey(bridgeID: bridgeID))
        lock.lock()
        cache[bridgeID] = value
        lock.unlock()
    }

    /// Forget cached offsets (tests; a defaults reset).
    static func resetCache() {
        lock.lock()
        cache = [:]
        lock.unlock()
    }

    private static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(userOffsetRange.upperBound, max(userOffsetRange.lowerBound, seconds))
    }
}
