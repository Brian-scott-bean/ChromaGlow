// onset.swift — how late a sound punch starts (chunk 2, low-latency capture).
//
// The Composer's onset punch decays from `AudioFeatures.lastOnsetAt`, the
// moment the hop that held the hit ARRIVED. This feeds the app's own
// AudioFeatureExtractor in the buffer sizes each capture path delivers — the
// old tap's ~100 ms (4800 frames) and MicrophoneHopRelay's 1024-frame hops —
// and measures, per beat, from the kick to the first published onset. Both
// arrive 4 ms after their last sample (dispatch; the relay's ≤ 5 ms I/O cycle
// is about the same as the tap's dispatch, so it is left out of both).

import Foundation

func onsetLatencyReport() {
    func run(_ r: Rendered, hop: Int) -> (median: Double, p90: Double, found: Int, total: Int) {
        let extractor = AudioFeatureExtractor()
        var onsets: [Double] = []   // arrival times of hops flagged as onsets
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * hop <= r.samples.count {
                let start = Double(k * hop) / r.fs
                let arrival = start + Double(hop) / r.fs + 0.004
                if let f = extractor.process(data: p.baseAddress! + k * hop, frameCount: hop,
                                             sampleRate: Float(r.fs), hostTime: arrival,
                                             captureTime: start + Double(hop) / r.fs / 2), f.isOnset {
                    onsets.append(arrival)
                }
                k += 1
            }
        }
        var lat: [Double] = []
        for b in r.beats {
            if let hit = onsets.first(where: { $0 >= b.time && $0 < b.time + 0.25 }) { lat.append(hit - b.time) }
        }
        lat.sort()
        func pct(_ q: Double) -> Double { lat.isEmpty ? .nan : lat[min(lat.count - 1, Int(Double(lat.count) * q))] * 1000 }
        return (pct(0.5), pct(0.9), lat.count, r.beats.count)
    }
    print("Punch start after the kick (ms; beats whose punch started within 250 ms)")
    for c in cases where c.rhythmic {
        let r = Synth.render(c.segments, seed: c.seed, noiseDB: c.noiseDB)
        let tap = run(r, hop: 4800), relay = run(r, hop: 1024)
        print("  " + c.name.padding(toLength: 22, withPad: " ", startingAt: 0)
              + String(format: "tap 4800: med %5.1f p90 %5.1f (%3d/%3d) | hops 1024: med %5.1f p90 %5.1f (%3d/%3d)",
                       tap.median, tap.p90, tap.found, tap.total,
                       relay.median, relay.p90, relay.found, relay.total))
    }
}
