import Foundation
// Simulates MusicSessionCoordinator's 1 Hz driveFromTrack (grid anchored at track t=0)
// while the mic path nudges phase — the "tug of war". Track position 0 == sample 0.
@MainActor
func runService(_ r: Rendered, trueBPM: Double, useV2Mic: Bool, micOn: Bool) -> [Snap] {
    let clock = BeatClock(); clock.clear()
    let extractor = AudioFeatureExtractor()
    let estimator = TempoEstimator()
    let odf = OnsetODF(fs: r.fs)
    let tp = TempoPhaseV2(frameRate: r.fs / 480)
    var snaps: [Snap] = []
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * 4800 <= r.samples.count {
            let start = Double(k * 4800) / r.fs
            let arrival = start + 0.1 + 0.004
            if k % 10 == 0 {
                // 1 Hz service drive: the player's position, captured "now".
                clock.driveFromTrack(bpm: trueBPM, position: PlaybackPosition(positionMs: Int((arrival * 1000).rounded()), capturedAt: arrival, isPlaying: true),
                                     confidence: 1, now: arrival)
            }
            if micOn {
                if useV2Mic {
                    odf.push(p.baseAddress! + k * 4800, count: 4800, bufferStartTime: start)
                    if k % 5 == 4, let tEnd = odf.times.last {
                        tp.bandHistory = odf.bands; tp.allHigh = odf.high
                        if let e = tp.update(odf: odf.odf, low: odf.low, mid: odf.mid, times: odf.times) {
                            clock.ingest(estimate: TempoEstimate(bpm: e.bpm, confidence: e.confidence >= 0.3 ? 0.9 : 0.1, lastBeatOffset: tEnd - e.lastBeatTime), endTime: tEnd)
                        }
                    }
                } else {
                    _ = extractor.process(data: p.baseAddress! + k * 4800, frameCount: 4800, sampleRate: Float(r.fs), hostTime: arrival, captureTime: start + 0.05)
                    if k % 5 == 4 {
                        let s = extractor.onsetEnvelopeSnapshot()
                        if let est = estimator.update(onsetEnvelope: s.envelope, hopRate: s.hopRate) { clock.ingest(estimate: est, endTime: s.endTime) }
                    }
                }
            }
            snaps.append(Snap(t: arrival + 0.01, s: BeatClock.snapshot(), conf: clock.confidence))
            k += 1
        }
    }
    return snaps
}

func serviceReport() {
    for (bpm, lead) in [(120.0, 0.37), (100.5, 0.6), (128.0, 0.05)] {
        let r = Synth.render([Segment(bpm: bpm, leadIn: lead, bars: 24)], seed: 7)
        MainActor.assumeIsolated {
            for (label, micOn, v2) in [("service only", false, false), ("service + today's mic", true, false), ("service + v2 mic", true, true)] {
                var st = evaluate("", snaps: runService(r, trueBPM: bpm, useV2Mic: v2, micOn: micOn), beats: r.beats, warmup: 10, segmentStarts: [lead])
                st.lockTime = nil
                let line = st.line()
                let phase = line.components(separatedBy: "| phase")[1].components(separatedBy: "| bar")[0]
                print(String(format: "%5.1f BPM lead-in %.2fs  %-22@ phase%@", bpm, lead, label as NSString, phase))
            }
        }
    }
}
