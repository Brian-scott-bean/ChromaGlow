// ArrangementSynth.swift — synthetic dance-music arrangements with exact
// truth for sections, phrases, builds and drops (builds 920–922).
//
// The licence-clean corpus has no music annotated with builds and drops (the
// EDM-drop set's audio has no per-track licence and was skipped — see
// raw/edm-drops-ssme/SOURCE.txt), so the song-structure work is measured on
// arrangements rendered here, deterministically, with the build cues the
// literature names (research doc §4): the low end taken away, a snare roll
// doubling in rate, a noise riser climbing in level and pitch, a loudness
// ramp and a one-beat gap before the drop, where the kick and the bass (a
// pure sub plus a saw an octave up, build 921) return. Real songs (BabySlakh) are used for what they can say: where the
// instrumentation changes (phrases), and how often a non-dance song is
// wrongly called a drop.

import Foundation

enum ArrPart: String, CaseIterable {
    case intro, verse, build, drop, breakdown, fakeBuild, outro
}

struct ArrSection { var part: ArrPart; var bars: Int }

struct ArrSong {
    var name: String
    var bpm: Double
    var sections: [ArrSection]
    var seed: UInt64
    /// The intro and outro carry a four-on-the-floor kick (a DJ-friendly intro).
    var kickIntro = false
}

struct ArrRender {
    var samples: [Float]
    var bpm: Double
    /// Time of bar 0's downbeat.
    var firstDownbeat: Double
    var barSeconds: Double
    /// Every section: its part, the time and bar it starts on.
    var sections: [(part: ArrPart, time: Double, bar: Int)]
    /// Every downbeat time (bar lines).
    var barLines: [Double]
    var duration: Double

    var drops: [Double] { sections.filter { $0.part == .drop }.map(\.time) }
    var builds: [(start: Double, end: Double, real: Bool)] {
        sections.indices.compactMap { i in
            let s = sections[i]
            guard s.part == .build || s.part == .fakeBuild else { return nil }
            let end = i + 1 < sections.count ? sections[i + 1].time : duration
            return (s.time, end, s.part == .build)
        }
    }
}

enum ArrangementSynth {
    /// The test set: eight arrangements, 100–172 BPM, 8- and 16-bar sections,
    /// a build that leads nowhere, and one 4-bar build (a drop off the 8-bar grid).
    static let songs: [ArrSong] = [
        ArrSong(name: "house-124", bpm: 124, sections: [.init(part: .intro, bars: 8), .init(part: .verse, bars: 16),
            .init(part: .build, bars: 8), .init(part: .drop, bars: 16), .init(part: .breakdown, bars: 8),
            .init(part: .build, bars: 8), .init(part: .drop, bars: 16), .init(part: .outro, bars: 8)], seed: 1, kickIntro: true),
        ArrSong(name: "edm-128", bpm: 128, sections: [.init(part: .intro, bars: 8), .init(part: .build, bars: 8),
            .init(part: .drop, bars: 16), .init(part: .breakdown, bars: 16), .init(part: .build, bars: 16),
            .init(part: .drop, bars: 16), .init(part: .outro, bars: 8)], seed: 2),
        ArrSong(name: "trance-138", bpm: 138, sections: [.init(part: .intro, bars: 16), .init(part: .breakdown, bars: 16),
            .init(part: .build, bars: 16), .init(part: .drop, bars: 32), .init(part: .outro, bars: 8)], seed: 3, kickIntro: true),
        ArrSong(name: "fake-126", bpm: 126, sections: [.init(part: .intro, bars: 8), .init(part: .verse, bars: 8),
            .init(part: .fakeBuild, bars: 8), .init(part: .verse, bars: 8), .init(part: .build, bars: 8),
            .init(part: .drop, bars: 16), .init(part: .breakdown, bars: 8), .init(part: .build, bars: 8),
            .init(part: .drop, bars: 16)], seed: 4),
        ArrSong(name: "pop-110", bpm: 110, sections: [.init(part: .intro, bars: 8), .init(part: .verse, bars: 16),
            .init(part: .build, bars: 8), .init(part: .drop, bars: 16), .init(part: .verse, bars: 16),
            .init(part: .build, bars: 8), .init(part: .drop, bars: 16), .init(part: .outro, bars: 8)], seed: 5),
        ArrSong(name: "dnb-172", bpm: 172, sections: [.init(part: .intro, bars: 16), .init(part: .build, bars: 8),
            .init(part: .drop, bars: 32), .init(part: .breakdown, bars: 16), .init(part: .build, bars: 8),
            .init(part: .drop, bars: 16)], seed: 6),
        ArrSong(name: "slow-100", bpm: 100, sections: [.init(part: .intro, bars: 8), .init(part: .verse, bars: 16),
            .init(part: .breakdown, bars: 8), .init(part: .build, bars: 8), .init(part: .drop, bars: 16),
            .init(part: .outro, bars: 8)], seed: 7),
        ArrSong(name: "short-build-130", bpm: 130, sections: [.init(part: .intro, bars: 8), .init(part: .verse, bars: 12),
            .init(part: .build, bars: 4), .init(part: .drop, bars: 16), .init(part: .breakdown, bars: 8),
            .init(part: .build, bars: 8), .init(part: .drop, bars: 16)], seed: 8),
    ]

    // Am F C G — bass roots and pad chords.
    private static let roots: [Double] = [55, 43.65, 65.41, 49]
    private static let chords: [[Double]] = [[220, 261.6, 329.6], [174.6, 220, 261.6], [261.6, 329.6, 392], [196, 246.9, 293.7]]

    static func render(_ song: ArrSong, fs: Double = 48_000, leadIn: Double = 1.0) -> ArrRender {
        var rng = SplitMix(s: song.seed &* 0x9E37_79B9 &+ 17)
        let beat = 60 / song.bpm
        let bar = 4 * beat
        let totalBars = song.sections.reduce(0) { $0 + $1.bars }
        let duration = leadIn + Double(totalBars) * bar + 1.5
        var out = [Float](repeating: 0, count: Int(duration * fs))
        let kick = Synth.kickWave(fs: fs)
        let snare = Synth.snareWave(fs: fs, rng: &rng)
        let hat = Synth.hatWave(fs: fs, rng: &rng)
        var sections: [(part: ArrPart, time: Double, bar: Int)] = []
        var barLines: [Double] = []
        var b = 0
        for (si, section) in song.sections.enumerated() {
            let sectionStart = leadIn + Double(b) * bar
            sections.append((section.part, sectionStart, b))
            let nextIsDrop = si + 1 < song.sections.count && song.sections[si + 1].part == .drop
            for j in 0..<section.bars {
                let t0 = leadIn + Double(b) * bar
                barLines.append(t0)
                let progress = Double(j) / Double(max(1, section.bars))      // 0…1 through the section
                let chord = chords[b % 4], root = roots[b % 4]
                let lastBarOfBuild = (section.part == .build || section.part == .fakeBuild) && j == section.bars - 1
                for k in 0..<4 {
                    let t = t0 + Double(k) * beat
                    // The one-beat gap before a drop: silence on the build's last beat.
                    if lastBarOfBuild && k == 3 && nextIsDrop { continue }
                    switch section.part {
                    case .intro, .outro:
                        if song.kickIntro { Synth.add(&out, kick, at: t, fs: fs, gain: 0.7) }
                        Synth.add(&out, hat, at: t + beat / 2, fs: fs, gain: 0.25)
                    case .verse:
                        Synth.add(&out, kick, at: t, fs: fs, gain: 0.8)
                        if k % 2 == 1 { Synth.add(&out, snare, at: t, fs: fs, gain: 0.5) }
                        Synth.add(&out, hat, at: t, fs: fs, gain: 0.15)
                        Synth.add(&out, hat, at: t + beat / 2, fs: fs, gain: 0.25)
                        Synth.addBass(&out, fs: fs, at: t + beat / 2, length: beat / 2 - 0.01, freq: root * 2, amp: 0.18)
                        addSaw(&out, fs: fs, at: t + beat / 2, length: beat / 2 - 0.01, freq: root * 2, amp: 0.08)
                    case .build, .fakeBuild:
                        // Kick for the first half, then the low end is gone.
                        if progress < 0.5 { Synth.add(&out, kick, at: t, fs: fs, gain: Float(0.7 * (1 - progress))) }
                        // The snare roll doubles: quarters, eighths, sixteenths, (last bar) thirty-seconds.
                        let perBeat = lastBarOfBuild ? 8 : progress < 0.5 ? 1 : progress < 0.75 ? 2 : 4
                        for r in 0..<perBeat {
                            // Louder through the build, but a faster roll isn't a louder one.
                            let g = Float((0.15 + 0.3 * (progress + Double(k) / 4 / Double(section.bars))) / Double(perBeat).squareRoot())
                            Synth.add(&out, snare, at: t + Double(r) * beat / Double(perBeat), fs: fs, gain: g)
                        }
                    case .drop:
                        Synth.add(&out, kick, at: t, fs: fs, gain: 1.0)
                        if k % 2 == 1 { Synth.add(&out, snare, at: t, fs: fs, gain: 0.6) }
                        Synth.add(&out, hat, at: t, fs: fs, gain: 0.2)
                        Synth.add(&out, hat, at: t + beat / 2, fs: fs, gain: 0.3)
                        // A sub (pure, below 141 Hz) with a saw layer an octave up (its
                        // harmonics reach the bass-line lane's 141–375 Hz).
                        Synth.addBass(&out, fs: fs, at: t, length: beat / 2 - 0.01, freq: root, amp: 0.35)
                        Synth.addBass(&out, fs: fs, at: t + beat / 2, length: beat / 2 - 0.01, freq: root, amp: 0.35)
                        addSaw(&out, fs: fs, at: t, length: beat - 0.01, freq: root * 2, amp: 0.18)
                        // A lead stab on the off-beat.
                        Synth.addPad(&out, fs: fs, at: t + beat / 2, length: beat / 3, freqs: chord.map { $0 * 2 }, amp: 0.05)
                    case .breakdown:
                        break
                    }
                }
                // The pad: every section but the drop (softer there), louder through a build.
                let padAmp: Double
                switch section.part {
                case .drop: padAmp = 0.025
                case .breakdown: padAmp = 0.07
                case .build, .fakeBuild: padAmp = 0.03 + 0.05 * progress
                default: padAmp = 0.04
                }
                let padLength = (lastBarOfBuild && nextIsDrop) ? 3 * beat : bar
                Synth.addPad(&out, fs: fs, at: t0, length: padLength, freqs: chord, amp: padAmp)
                if section.part == .breakdown {
                    // A soft melody over the pad.
                    for k in 0..<4 {
                        Synth.addPad(&out, fs: fs, at: t0 + Double(k) * beat, length: beat * 0.9,
                                     freqs: [chord[k % 3] * 2], amp: 0.04)
                    }
                }
                b += 1
            }
            // The riser over a build: noise climbing in level and pitch.
            if section.part == .build || section.part == .fakeBuild {
                let start = Int(sectionStart * fs)
                let end = Int((sectionStart + Double(section.bars) * bar - (nextIsDrop ? beat : 0)) * fs)
                var prevX: Float = 0, prevY: Float = 0
                for i in start..<min(end, out.count) {
                    let u = Double(i - start) / Double(max(1, end - start))
                    let cutoff = 300 * pow(5000.0 / 300, u)
                    let rc = 1 / (2 * .pi * cutoff)
                    let a = Float(rc / (rc + 1 / fs))
                    let x = Float(rng.gauss())
                    let y = a * (prevY + x - prevX)
                    prevX = x; prevY = y
                    out[i] += y * Float(0.01 + 0.07 * u * u)
                }
            }
        }
        return ArrRender(samples: out, bpm: song.bpm, firstDownbeat: leadIn, barSeconds: bar,
                         sections: sections, barLines: barLines, duration: duration)
    }

    /// A band-limited saw (8 harmonics), plucked and released.
    static func addSaw(_ out: inout [Float], fs: Double, at time: Double, length: Double, freq: Double, amp: Double) {
        let start = Int(time * fs), len = Int(length * fs)
        for i in 0..<len where start + i < out.count && start + i >= 0 {
            let t = Double(i) / fs
            let env = min(1, t / 0.005) * (t > length - 0.02 ? max(0, (length - t) / 0.02) : 1)
            var v = 0.0
            for k in 1...8 { v += sin(2 * .pi * Double(k) * freq * t) / Double(k) }
            out[start + i] += Float(amp * env * v)
        }
    }
}
