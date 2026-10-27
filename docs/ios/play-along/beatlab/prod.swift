// prod.swift — the PRODUCTION tracker (HueHome/Core/Audio/OnsetFrameAnalyzer +
// BeatTracker + BeatClock.ingest(observation:)) on the same synthetic audio,
// so the lab measures what ships, not only the prototype.

import Foundation

/// `hop` is what the microphone delivers: 1024 frames (~21 ms) since chunk 2
/// (MicrophoneHopRelay), 4800 (~100 ms) with the old tap. The tracker pass
/// runs every 0.5 s on whatever has arrived by then.
@MainActor
func runProd(_ r: Rendered, hop: Int = 1024) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    let analyzer = OnsetFrameAnalyzer()
    let tracker = BeatTracker()
    var snaps: [Snap] = []
    var nextPass = 0.5
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * hop <= r.samples.count {
            let start = Double(k * hop) / r.fs
            let arrival = start + Double(hop) / r.fs + 0.004
            analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: r.fs, bufferStart: start)
            if arrival >= nextPass {
                nextPass += 0.5
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
