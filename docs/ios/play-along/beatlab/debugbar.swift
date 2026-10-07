import Foundation
// Debug: for one case, print K/H slot vectors and the TRUE downbeat slot relative to lastBeat.
func debugBar(_ seg: Segment) {
    let r = Synth.render([seg], seed: 7)
    let odf = OnsetODF(fs: r.fs)
    let tp = TempoPhaseV2(frameRate: r.fs / 480)
    tp.debug = true
    r.samples.withUnsafeBufferPointer { p in
        var k = 0
        while (k + 1) * 4800 <= r.samples.count {
            odf.push(p.baseAddress! + k * 4800, count: 4800, bufferStartTime: Double(k * 4800) / r.fs)
            if k % 50 == 49 {
                tp.bandHistory = odf.bands; tp.allHigh = odf.high
                if let e = tp.update(odf: odf.odf, low: odf.low, mid: odf.mid, times: odf.times) {
                    // true downbeat slot: find true beat nearest lastBeat, its bar position
                    let nearest = r.beats.min { abs($0.time - e.lastBeatTime) < abs($1.time - e.lastBeatTime) }!
                    let i = r.beats.firstIndex { $0.time == nearest.time }!
                    // index within bar of that beat
                    let pos = i % 4
                    // downbeat relative index d satisfies (pos + d) % 4 == 0
                    let trueD = (4 - pos) % 4
                    print(String(format: "t=%5.1f lastBeat err %+5.1f ms  pick %d true %d  conf %.2f", odf.times.last!, (e.lastBeatTime - nearest.time) * 1000, e.downbeatPhaseBeats ?? -1, trueD, e.barConfidence), tp.lastSlots)
                }
            }
            k += 1
        }
    }
}
