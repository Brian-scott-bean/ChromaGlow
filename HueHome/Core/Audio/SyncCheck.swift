// SyncCheck.swift
// ChromaGlow — Core/Audio (chunk 2, item 3: Sync Check)
//
// Measures how long THIS bridge takes to show a frame. The live stream
// blinks the room slowly while the camera watches one of its lights; the
// delay from sending each blink to the light reaching half its brightness
// (as the camera sees it) is the bridge's real Entertainment latency, and
// OutputLatencyModel renders that far ahead from then on — replacing the
// 100 ms starting guess that docs/ios/play-along/README.md §8.1 asked to be
// measured.
//
// Everything here is pure and testable; the camera is SyncCheckCamera.swift.
//
//   SyncCheckPlan      when to blink: jittered starts, far under the flash limit
//   SyncCheckPattern   the frame source the live stream plays meanwhile
//   SyncCheckAnalyzer  camera brightness samples + send times → the delay
//   SyncCheckLuma      a camera frame → a grid of brightness cells

import Foundation

// MARK: - Plan

/// When the room blinks. Blink starts are jittered so they land on frames at
/// every phase the stream has against the bridge's 25 Hz radio updates: the
/// measured delay then includes the average wait for the next update —
/// exactly what a rendered beat pays.
/// About one blink a second, each 0.35 s: well under the 3-per-second flash
/// limit, and every rise is ≥ 0.9 s from the last (the gate needs 0.34 s).
struct SyncCheckPlan: Sendable, Equatable {
    static let blinkCount = 14
    static let spacing: ClosedRange<Double> = 0.9...1.3
    /// Warm white (about 2700 K).
    static let colour = (x: 0.4578, y: 0.4101)

    /// Seconds at the blink level first, so the camera sets its exposure on a lit room.
    let settle: Double
    /// Dark before the first blink.
    let gap: Double
    /// How long each blink stays on.
    let onDuration: Double
    /// Blink starts, seconds from the start of the plan.
    let onsets: [Double]
    let offLevel: Double
    let onLevel: Double

    /// `dimFlashing`: the system's Dim Flashing Lights — a smaller step,
    /// which the camera still sees.
    init(seed: UInt64, dimFlashing: Bool, blinkCount: Int = SyncCheckPlan.blinkCount) {
        settle = 1.5
        gap = 0.6
        onDuration = 0.35
        offLevel = 0.06
        onLevel = dimFlashing ? 0.45 : 1
        var random = SyncCheckRandom(seed: seed)
        var t = settle + gap
        var starts: [Double] = []
        for _ in 0..<max(1, blinkCount) {
            starts.append(t)
            t += Self.spacing.lowerBound + (Self.spacing.upperBound - Self.spacing.lowerBound) * random.unit()
        }
        onsets = starts
    }

    /// The whole check: the last blink plus room for the slowest delay the
    /// analyzer accepts and the light's plateau after it.
    var duration: Double { (onsets.last ?? 0) + SyncCheckAnalyzer.maxDelay + onDuration + 0.1 }

    /// The blink on at `t` (seconds into the plan), if any.
    func blink(at t: Double) -> Int? {
        onsets.firstIndex { t >= $0 && t < $0 + onDuration }
    }

    func level(at t: Double) -> Double {
        if t >= 0 && t < settle { return onLevel }
        return blink(at: t) == nil ? offLevel : onLevel
    }
}

/// SplitMix64: a seeded, reproducible jitter (tests replay a plan exactly).
private struct SyncCheckRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Pattern

/// The frame source the live stream plays during a Sync Check. It wraps the
/// look that was playing and keeps rendering it unseen, so the look's clock
/// and the playback center's heartbeat carry on; once the plan is over it
/// shows the look again, and the center hands the look back to the box.
///
/// Blinks are rendered for the moment they are SENT — no render lead: the
/// point is to measure what the lead should be. The plan starts at the first
/// frame the stream asks for, and each blink's send time is the first frame
/// that rendered it (the loop sends that frame straight away).
final class SyncCheckPattern: ConcurrentCompositionFrameSource, @unchecked Sendable {
    let plan: SyncCheckPlan

    private let lock = NSLock()
    private var _wrapped: (any ConcurrentCompositionFrameSource)?
    private var _startedAt: Double?
    private var _lastRenderAt: Double = 0
    private var _sentAt: [Double?]

    init(plan: SyncCheckPlan) {
        self.plan = plan
        _sentAt = Array(repeating: nil, count: plan.onsets.count)
    }

    /// The look underneath.
    var wrapped: (any ConcurrentCompositionFrameSource)? {
        lock.lock(); defer { lock.unlock() }
        return _wrapped
    }

    func wrap(_ source: (any ConcurrentCompositionFrameSource)?) {
        lock.lock(); _wrapped = source; lock.unlock()
    }

    /// Host time of the first frame (the plan's zero); nil until the stream renders it.
    var startedAt: Double? {
        lock.lock(); defer { lock.unlock() }
        return _startedAt
    }

    /// Host time of the newest frame. A pattern that stops being asked for
    /// frames was replaced (a new look, a stop) — the check is over.
    var lastRenderAt: Double {
        lock.lock(); defer { lock.unlock() }
        return _lastRenderAt
    }

    /// When each blink first went out (host seconds); nil until it has.
    var sentAt: [Double?] {
        lock.lock(); defer { lock.unlock() }
        return _sentAt
    }

    var blinksSent: Int { sentAt.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    func isFinished(at hostNow: Double) -> Bool {
        guard let start = startedAt else { return false }
        return hostNow - start >= plan.duration
    }

    func renderLiveFrames(time: Double, channelIDs: [Int], layout: CompositionLiveLayout,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        let look = wrapped?.renderLiveFrames(time: time, channelIDs: channelIDs, layout: layout,
                                             features: features, beat: beat, hostNow: hostNow)
        return frames(channelIDs: channelIDs, hostNow: hostNow, look: look)
    }

    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        let look = wrapped?.renderFrames(time: time, channelIDs: channelIDs, params: params,
                                         features: features, beat: beat, hostNow: hostNow)
        return frames(channelIDs: channelIDs, hostNow: hostNow, look: look)
    }

    private func frames(channelIDs: [Int], hostNow: Double, look: [LightFrame]?) -> [LightFrame] {
        lock.lock()
        if _startedAt == nil { _startedAt = hostNow }
        _lastRenderAt = hostNow
        let t = hostNow - (_startedAt ?? hostNow)
        let blink = plan.blink(at: t)
        if let blink, _sentAt[blink] == nil { _sentAt[blink] = hostNow }
        lock.unlock()
        if t >= plan.duration, let look, look.count == channelIDs.count { return look }
        let level = plan.level(at: t)
        return channelIDs.map {
            LightFrame(channelID: $0, x: SyncCheckPlan.colour.x, y: SyncCheckPlan.colour.y, brightness: level)
        }
    }
}

// MARK: - Analyzer

/// One camera frame: when it was captured (host seconds, the clock
/// CACurrentMediaTime reads, at the middle of the exposure) and the mean
/// brightness of each grid cell.
struct SyncCheckSample: Sendable, Equatable {
    let time: Double
    let cells: [Float]
}

enum SyncCheckAnalyzer {
    struct Measurement: Equatable, Sendable {
        /// Delay from sending a blink to the light at half brightness: the
        /// mean of the middle half of the blinks.
        let latency: Double
        /// Interquartile range of the per-blink delays.
        let spread: Double
        let delays: [Double]
        /// The grid cell that watched the light.
        let cell: Int
        let blinksSent: Int
    }

    enum Failure: Error, Equatable {
        /// No part of the picture blinked with the pattern.
        case lightNotSeen
        /// The light was seen, but too few blinks could be timed.
        case tooFewBlinks(seen: Int, sent: Int)
        /// The delays disagree too much to trust (a moving camera, a flickering light).
        case inconsistent(spread: Double)
    }

    /// The slowest delay accepted. Signify publishes none; the community
    /// measures ~80 ms, and a slow bridge or a busy network adds to it.
    static let maxDelay = 0.5
    /// Brightness units (0–255) a blink must change the watched cell by.
    static let minContrast: Float = 6
    static let maxSpread = 0.06
    /// A rise straddling a longer gap between frames (dropped frames) is not timed.
    static let maxFrameGap = 0.035

    static func measure(samples: [SyncCheckSample], sentAt: [Double?],
                        onDuration: Double) -> Result<Measurement, Failure> {
        let sent = sentAt.compactMap { $0 }.sorted()
        guard let cellCount = samples.first?.cells.count, cellCount > 0, sent.count >= 3 else {
            return .failure(.lightNotSeen)
        }
        let usable = samples.filter { $0.cells.count == cellCount }.sorted { $0.time < $1.time }
        guard usable.count >= 20 else { return .failure(.lightNotSeen) }
        let times = usable.map(\.time)

        // 1. Which cell blinks with the pattern, and at about what delay: the
        //    (cell, delay) whose predicted on-times split its samples into the
        //    most different means, in units of its own spread. Searched on
        //    10 ms bins with running totals, so every candidate costs one
        //    subtraction per blink (fast even in a Debug build).
        guard let best = coarseSearch(usable, sent: sent, cellCount: cellCount, onDuration: onDuration),
              best.contrast >= minContrast else { return .failure(.lightNotSeen) }
        let values = usable.map { $0.cells[best.cell] }

        // 2. Each blink against its OWN dark and lit levels, away from its
        //    edges: a light that drifts out of view, or an exposure that
        //    wanders, only costs the blinks it touches.
        var windows: [(sent: Double, dark: Float, lit: Float)] = []
        var deviations: [Float] = []
        for s in sent {
            let dark = slice(from: s + best.lag - 0.25, to: s + best.lag - 0.04, of: values, times: times)
            let lit = slice(from: s + best.lag + onDuration * 0.5, to: s + best.lag + onDuration - 0.02,
                            of: values, times: times)
            guard !dark.isEmpty, !lit.isEmpty else { continue }
            let darkLevel = median(dark)
            deviations.append(contentsOf: dark.map { abs($0 - darkLevel) })
            windows.append((s, darkLevel, median(lit)))
        }
        let noise = 1.4826 * median(deviations)
        let needed = max(minContrast, 5 * noise)
        let seen = windows.filter { $0.lit - $0.dark >= needed }
        guard !seen.isEmpty else { return .failure(.lightNotSeen) }

        // 3. When the light first crossed half way, interpolated between the
        //    two frames either side of it.
        var delays: [Double] = []
        for window in seen {
            let s = window.sent
            let threshold = window.dark + (window.lit - window.dark) / 2
            let from = index(atOrAfter: s + max(0, best.lag - 0.15), in: times)
            let to = index(atOrAfter: s + min(maxDelay + 0.05, best.lag + 0.15), in: times)
            guard from >= 1, to > from, values[from - 1] < threshold else { continue }
            for k in from..<min(to + 1, values.count) where values[k - 1] < threshold && values[k] >= threshold {
                let gap = times[k] - times[k - 1]
                guard gap <= maxFrameGap else { break }
                let fraction = Double((threshold - values[k - 1]) / (values[k] - values[k - 1]))
                let crossing = times[k - 1] + fraction * gap
                if crossing >= s, crossing - s <= maxDelay { delays.append(crossing - s) }
                break
            }
        }
        // A handful of chance matches (a TV, a passing shadow) is not a light.
        guard delays.count >= max(3, sent.count / 4) else { return .failure(.lightNotSeen) }
        let wanted = max(6, Int((Double(sent.count) * 0.6).rounded(.up)))
        guard delays.count >= wanted else { return .failure(.tooFewBlinks(seen: delays.count, sent: sent.count)) }
        let sorted = delays.sorted()
        let spread = quantile(sorted, 0.75) - quantile(sorted, 0.25)
        guard spread <= maxSpread else { return .failure(.inconsistent(spread: spread)) }
        return .success(Measurement(latency: interquartileMean(sorted), spread: spread, delays: delays,
                                    cell: best.cell, blinksSent: sent.count))
    }

    private static let bin = 0.01

    private static func coarseSearch(_ samples: [SyncCheckSample], sent: [Double], cellCount: Int,
                                     onDuration: Double) -> (cell: Int, lag: Double, contrast: Float)? {
        let regionStart = sent[0] - 0.3
        let regionEnd = sent[sent.count - 1] + maxDelay + onDuration + 0.1
        let bins = Int(((regionEnd - regionStart) / bin).rounded(.up))
        guard bins > 0 else { return nil }
        // Per-bin totals, then running totals over bins: [cell * (bins + 1) + b].
        var sums = [Double](repeating: 0, count: cellCount * (bins + 1))
        var counts = [Double](repeating: 0, count: bins + 1)
        var squares = [Double](repeating: 0, count: cellCount)
        var inRegion = 0
        sums.withUnsafeMutableBufferPointer { sums in
            for sample in samples {
                let b = Int(((sample.time - regionStart) / bin).rounded(.down))
                guard b >= 0, b < bins else { continue }
                counts[b + 1] += 1
                inRegion += 1
                sample.cells.withUnsafeBufferPointer { cells in
                    for c in 0..<cellCount {
                        let v = Double(cells[c])
                        sums[c * (bins + 1) + b + 1] += v
                        squares[c] += v * v
                    }
                }
            }
            for b in 0..<bins { counts[b + 1] += counts[b] }
            for c in 0..<cellCount {
                let row = c * (bins + 1)
                for b in 0..<bins { sums[row + b + 1] += sums[row + b] }
            }
        }
        guard inRegion >= 20 else { return nil }
        let total = Double(inRegion)
        let deviation = (0..<cellCount).map { c -> Double in
            let mean = sums[c * (bins + 1) + bins] / total
            return max(0, squares[c] / total - mean * mean).squareRoot()
        }

        let onBins = Int((onDuration / bin).rounded())
        let starts = sent.map { Int((($0 - regionStart) / bin).rounded(.down)) }
        var best: (score: Double, cell: Int, lag: Double, contrast: Float)?
        for step in 0...Int((maxDelay / bin).rounded()) {
            let ranges = starts.map { (min(bins, max(0, $0 + step)), min(bins, max(0, $0 + step + onBins))) }
            let onCount = ranges.reduce(0.0) { $0 + counts[$1.1] - counts[$1.0] }
            let offCount = total - onCount
            guard onCount > 0, offCount > 0 else { continue }
            for c in 0..<cellCount {
                let row = c * (bins + 1)
                let onSum = ranges.reduce(0.0) { $0 + sums[row + $1.1] - sums[row + $1.0] }
                let contrast = onSum / onCount - (sums[row + bins] - onSum) / offCount
                let score = contrast / (deviation[c] + 0.5)
                if score > (best?.score ?? 0) { best = (score, c, Double(step) * bin, Float(contrast)) }
            }
        }
        return best.map { ($0.cell, $0.lag, $0.contrast) }
    }

    // MARK: Helpers

    /// First index whose time is ≥ `t` (times sorted).
    private static func index(atOrAfter t: Double, in times: [Double]) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func slice(from: Double, to: Double, of values: [Float], times: [Double]) -> [Float] {
        guard to > from else { return [] }
        let lo = index(atOrAfter: from, in: times), hi = index(atOrAfter: to, in: times)
        return hi > lo ? Array(values[lo..<hi]) : []
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The mean of the middle half of sorted values. The stream's 20 ms
    /// frames meet the radio's 40 ms updates at only two phases, so the
    /// delays can split into two groups 20 ms apart; beats ride on both, so
    /// the lead is their mean — a median would pick one of the two.
    private static func interquartileMean(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let drop = sorted.count / 4
        let middle = sorted[drop..<(sorted.count - drop)]
        return middle.reduce(0, +) / Double(middle.count)
    }

    /// Linear-interpolated quantile of sorted values.
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

// MARK: - Camera frame → brightness grid

enum SyncCheckLuma {
    /// The grid the camera frame is reduced to (landscape, as the sensor reads).
    static let columns = 16
    static let rows = 9

    /// Mean of every `step`-th pixel of an 8-bit luma plane, per grid cell.
    static func grid(_ plane: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                     columns: Int = SyncCheckLuma.columns, rows: Int = SyncCheckLuma.rows,
                     step: Int = 5) -> [Float] {
        guard width > 0, height > 0, columns > 0, rows > 0, step > 0 else { return [] }
        var sums = [UInt32](repeating: 0, count: columns * rows)
        var counts = [UInt32](repeating: 0, count: columns * rows)
        var columnOf: [Int] = []
        var x = step / 2
        while x < width {
            columnOf.append(min(columns - 1, x * columns / width))
            x += step
        }
        var y = step / 2
        while y < height {
            let rowBase = min(rows - 1, y * rows / height) * columns
            let line = plane + y * bytesPerRow
            var xi = 0
            var px = step / 2
            while px < width {
                let cell = rowBase + columnOf[xi]
                sums[cell] &+= UInt32(line[px])
                counts[cell] &+= 1
                xi += 1
                px += step
            }
            y += step
        }
        return zip(sums, counts).map { $1 > 0 ? Float($0) / Float($1) : 0 }
    }
}
