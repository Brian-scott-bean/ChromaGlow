// CompositionMixer.swift
// ChromaGlow — Round 3 Phase C (Perform surface)
//
// A/B deck blending at the render chokepoint: deck A is the LIVE
// composition's param box (the mixer is keyed to it by identity), deck B
// is the cued preset. renderMixed lerps the two rendered frame sets
// (xy + brightness — same math as gradient palettes), lays punch pads on
// top as a post-blend priority layer, then applies the master fader.
// Works identically on DTLS (25 fps) and REST because it lives at the
// same pure chokepoint as CompositionEngine.render.
//
// Safety: the strobe punch is hard-capped at ≤3 Hz (WCAG 2.3.1) no matter
// what the clock says; every punch release ramps back over 200 ms.

import Foundation

// MARK: - PerformanceMixBox

/// Live mix state — MainActor-written (Perform UI), render-loop read.
/// Same @unchecked Sendable reference convention as CompositionParamBox.
final class PerformanceMixBox: @unchecked Sendable {

    enum PunchPad: Equatable {
        case strobe
        case blackout
        case whiteBurst
    }

    /// Beat-exact auto-fade: crossfade DERIVED from the shared clock each
    /// frame (never accumulated), so it lands on the bar even if UI hitches.
    struct AutoFade {
        let fromValue: Double
        let toValue: Double
        let startBeats: Double     // continuous beats at start
        let totalBeats: Double     // fade length in beats
    }

    /// Deck A: the live composition's own param box (identity ties the mix
    /// to the loop that renders it).
    let deckA: CompositionParamBox
    var deckB: CompositionParamBox?
    var crossfade: Double = 0          // 0 = full A … 1 = full B
    var masterIntensity: Double = 1.0  // post-blend brightness scalar
    var autoFade: AutoFade? = nil

    // Punch state (momentary; release ramps 200 ms).
    var punch: PunchPad? = nil
    var punchHeld = false
    var punchReleasedAt: Double? = nil

    init(deckA: CompositionParamBox) {
        self.deckA = deckA
    }

    // UI entry points (MainActor by convention).
    func engagePunch(_ pad: PunchPad) {
        punch = pad
        punchHeld = true
        punchReleasedAt = nil
    }

    func releasePunch(hostNow: Double) {
        punchHeld = false
        punchReleasedAt = hostNow
    }

    /// Start a bar-aligned auto-fade toward the opposite deck.
    func startAutoFade(bars: Int, beat: BeatSnapshot, hostNow: Double) {
        startAutoFade(beats: Double(max(1, bars) * max(1, beat.beatsPerBar)),
                      beat: beat, hostNow: hostNow)
    }

    /// Beat-count variant (the sequencer fades over crossfadeBeats).
    func startAutoFade(beats: Double, beat: BeatSnapshot, hostNow: Double) {
        guard beat.bpm > 0, beats > 0 else {
            // No clock: land instantly rather than hang mid-fade.
            crossfade = crossfade < 0.5 ? 1.0 : 0.0
            autoFade = nil
            return
        }
        let beatsNow = (hostNow - beat.beatEpoch) / beat.beatInterval
        autoFade = AutoFade(fromValue: crossfade,
                            toValue: crossfade < 0.5 ? 1.0 : 0.0,
                            startBeats: beatsNow,
                            totalBeats: beats)
    }
}

// MARK: - CompositionMixer

enum CompositionMixer {

    /// WCAG 2.3.1: general flash threshold — never exceeded by the strobe pad.
    static let strobeMaxHz = 3.0
    static let punchReleaseSeconds = 0.2
    private static let d65 = (x: 0.3127, y: 0.3290)

    /// Drop-in replacement for CompositionEngine.render at both transports.
    static func renderMixed(
        time: Double,
        channelIDs: [UInt8],
        mix: PerformanceMixBox,
        features: AudioFeatures = .silent,
        beat: BeatSnapshot = .none,
        hostNow: Double = 0
    ) -> [LightFrame] {
        // ── Crossfade (auto-fade derives from the clock, beat-exact) ──
        var xf = min(1, max(0, mix.crossfade))
        if let auto = mix.autoFade {
            if beat.bpm > 0 {
                let beatsNow = (hostNow - beat.beatEpoch) / beat.beatInterval
                let t = (beatsNow - auto.startBeats) / max(0.001, auto.totalBeats)
                if t >= 1 {
                    xf = auto.toValue
                    mix.crossfade = auto.toValue
                    mix.autoFade = nil
                } else if t > 0 {
                    xf = auto.fromValue + (auto.toValue - auto.fromValue) * t
                    mix.crossfade = xf
                }
            } else {
                // Clock vanished mid-fade: land immediately rather than hang.
                xf = auto.toValue
                mix.crossfade = auto.toValue
                mix.autoFade = nil
            }
        }

        // ── Blend the decks ──
        let framesA = CompositionEngine.render(
            time: time, channelIDs: channelIDs, params: mix.deckA,
            features: features, beat: beat, hostNow: hostNow)
        var frames: [LightFrame]
        if let deckB = mix.deckB, xf > 0.001 {
            let framesB = CompositionEngine.render(
                time: time, channelIDs: channelIDs, params: deckB,
                features: features, beat: beat, hostNow: hostNow)
            frames = zip(framesA, framesB).map { a, b in
                LightFrame(channelID: a.channelID,
                           x: a.x + (b.x - a.x) * xf,
                           y: a.y + (b.y - a.y) * xf,
                           brightness: a.brightness + (b.brightness - a.brightness) * xf)
            }
        } else {
            frames = framesA
        }

        // ── Punch overlay (post-blend priority layer) ──
        frames = applyPunch(frames, mix: mix, beat: beat, hostNow: hostNow)

        // ── Master fader ──
        let master = min(1, max(0, mix.masterIntensity))
        if master < 0.999 {
            frames = frames.map {
                LightFrame(channelID: $0.channelID, x: $0.x, y: $0.y,
                           brightness: $0.brightness * master)
            }
        }
        return frames
    }

    /// Strength 1 while held → 0 over the 200 ms release ramp.
    static func punchStrength(mix: PerformanceMixBox, hostNow: Double) -> Double {
        guard mix.punch != nil else { return 0 }
        if mix.punchHeld { return 1 }
        guard let releasedAt = mix.punchReleasedAt else { return 0 }
        let t = (hostNow - releasedAt) / punchReleaseSeconds
        if t >= 1 {
            mix.punch = nil
            mix.punchReleasedAt = nil
            return 0
        }
        return 1 - max(0, t)
    }

    private static func applyPunch(_ frames: [LightFrame],
                                   mix: PerformanceMixBox,
                                   beat: BeatSnapshot,
                                   hostNow: Double) -> [LightFrame] {
        let strength = punchStrength(mix: mix, hostNow: hostNow)
        guard strength > 0, let pad = mix.punch else { return frames }

        switch pad {
        case .blackout:
            return frames.map {
                LightFrame(channelID: $0.channelID, x: $0.x, y: $0.y,
                           brightness: $0.brightness * (1 - strength))
            }

        case .whiteBurst:
            return frames.map {
                LightFrame(channelID: $0.channelID,
                           x: $0.x + (d65.x - $0.x) * strength,
                           y: $0.y + (d65.y - $0.y) * strength,
                           brightness: $0.brightness + (1 - $0.brightness) * strength)
            }

        case .strobe:
            // Flash rate follows the beat but NEVER exceeds 3 Hz — at
            // 174 BPM (2.9 Hz) it strobes on the beat; past 180 it clamps.
            let hz = beat.bpm > 0 ? min(strobeMaxHz, beat.bpm / 60.0) : strobeMaxHz
            let phase: Double
            if beat.bpm > 0, beat.bpm / 60.0 <= strobeMaxHz {
                phase = beat.beatPhase(at: hostNow)          // on the grid
            } else {
                phase = (hostNow * hz).truncatingRemainder(dividingBy: 1)
            }
            let on = phase < 0.5
            return frames.map {
                let target = on ? 1.0 : 0.0
                return LightFrame(channelID: $0.channelID,
                                  x: $0.x + (d65.x - $0.x) * strength,
                                  y: $0.y + (d65.y - $0.y) * strength,
                                  brightness: $0.brightness + (target - $0.brightness) * strength)
            }
        }
    }
}
