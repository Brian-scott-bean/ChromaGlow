// prod.swift — the PRODUCTION tracker (HueHome/Core/Audio/OnsetFrameAnalyzer +
// BeatTracker + BeatClock.ingest(observation:)) on the same synthetic audio,
// so the lab measures what ships, not only the prototype.

import Foundation

@MainActor
func runProd(_ r: Rendered) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    let analyzer = OnsetFrameAnalyzer()
    let tracker = BeatTracker()
    var snaps: [Snap] = []
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * 4800 <= r.samples.count {
            let start = Double(k * 4800) / r.fs
            let arrival = start + 0.1 + 0.004
            analyzer.process(p.baseAddress! + k * 4800, frameCount: 4800, sampleRate: r.fs, bufferStart: start)
            if k % 5 == 4 {
                if let o = tracker.update(analyzer.snapshot(seconds: BeatTracker.windowSeconds + 2)) {
                    clock.ingest(observation: o)
                } else {
                    clock.noteNoBeat(at: arrival)   // as AudioAnalysisEngine.trackerPass does
                }
                snaps.append(Snap(t: arrival + 0.01, s: BeatClock.snapshot(), conf: clock.confidence))
            }
            k += 1
        }
    }
    return snaps
}
