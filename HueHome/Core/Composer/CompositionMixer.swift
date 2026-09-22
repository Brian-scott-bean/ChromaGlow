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

    /// Beat-exact auto-fade: crossfade DERIVED each frame (never
    /// accumulated) from the host time elapsed since the start, measured in
    /// the clock's beats — so it lands on time even if UI hitches.
    ///
    /// Anchored on HOST time, not on the clock's beat count: Tap and Resync
    /// re-anchor `beatEpoch`, and a fade whose start was a beat count since
    /// the old epoch read negative progress afterwards and froze mid-fade.
    struct AutoFade {
        let fromValue: Double
        let toValue: Double
        let startHostTime: Double  // host time at start
        let totalBeats: Double     // fade length in beats

        /// 0 at the start, 1 after `totalBeats` beats at the current tempo.
        func progress(hostNow: Double, beat: BeatSnapshot) -> Double {
            guard beat.bpm > 0 else { return 1 }
            let elapsedBeats = (hostNow - startHostTime) / beat.beatInterval
            return elapsedBeats / max(0.001, totalBeats)
        }
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

    /// Peak brightness of the STROBE punch's ON phase. 1.0 normally; the
    /// Perform UI lowers it to `dimFlashingStrobeCeiling` while iOS "Dim
    /// Flashing Lights" is on (set on the main actor before the punch engages).
    var strobeCeiling: Double = 1.0
    /// Studio's Dim Flashing Lights cap for its strobe card — brightness 30 of
    /// 100 (StudioViewModel's `.appDriven("strobe")` start) — so the Perform
    /// pad dims exactly as far as the Studio strobe does.
    static let dimFlashingStrobeCeiling = 0.3

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
        autoFade = AutoFade(fromValue: crossfade,
                            toValue: crossfade < 0.5 ? 1.0 : 0.0,
                            startHostTime: hostNow,
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
    /// `channelIDs` are RENDER channel indices, not DTLS ids — see
    /// `LightFrame.channelID` (Composer 2 packet 5).
    static func renderMixed(
        time: Double,
        channelIDs: [Int],
        mix: PerformanceMixBox,
        features: AudioFeatures = .silent,
        beat: BeatSnapshot = .none,
        hostNow: Double = 0
    ) -> [LightFrame] {
        // ── Crossfade (auto-fade derives from the clock, beat-exact) ──
        var xf = min(1, max(0, mix.crossfade))
        if let auto = mix.autoFade {
            if beat.bpm > 0 {
                let t = auto.progress(hostNow: hostNow, beat: beat)
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
            // Dim Flashing Lights lowers the ON level, never the rate cap.
            let peak = min(1, max(0, mix.strobeCeiling))
            return frames.map {
                let target = on ? peak : 0.0
                return LightFrame(channelID: $0.channelID,
                                  x: $0.x + (d65.x - $0.x) * strength,
                                  y: $0.y + (d65.y - $0.y) * strength,
                                  brightness: $0.brightness + (target - $0.brightness) * strength)
            }
        }
    }
}
