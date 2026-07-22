// EnvelopeStripView.swift
// ChromaGlow — the Brightness Shape made visible.
//
// The engine has always computed six distinct envelope curves
// (EnvelopeConfig.value(at:)) that users chose from bare text chips.
// EnvelopeStripView draws the user's ACTUAL configured curve (shape, BPM,
// depth, attack/decay, duty, min/max) with a sweeping playhead;
// EnvelopeStripMath also provides tiny canonical per-shape thumbnails for
// the picker chips. MicLevelMeterView shows the live mic drive next to the
// reaction controls — it POLLS AudioAnalysisEngine.latestFeatures() and
// never starts the mic itself (demand ownership stays with the running
// composition).
//
// Perf discipline: 12fps TimelineViews paused by Reduce Motion,
// \.isTabActive, and KeyboardState; Reduce Motion keeps the static curve
// (information preserved, motion removed).

import SwiftUI

// MARK: - EnvelopeStripMath

enum EnvelopeStripMath {

    /// One preview cycle of the configured envelope, normalized 0…1 per
    /// sample. bpm shapes sample one (clamp-stretched) period; flicker has no
    /// period and samples a fixed window at the preview time scale.
    static func curvePoints(_ envelope: EnvelopeConfig, samples: Int = 48) -> [Double] {
        guard samples > 1 else { return [envelope.value(at: 0)] }
        let window = previewWindow(envelope)
        return (0..<samples).map { i in
            let t = window * Double(i) / Double(samples - 1)
            return min(1, max(0, LookPreviewMath.envelopeValue(envelope, at: t)))
        }
    }

    /// The real-time span the strip's x-axis covers (one clamped cycle).
    static func previewWindow(_ envelope: EnvelopeConfig) -> Double {
        switch envelope.shape {
        case .flicker: return 3.0
        case .steady:  return 1.0
        case .breathe, .heartbeat, .pulse, .swell:
            let period = 60.0 / max(1, envelope.bpm)
            return max(period, LookPreviewMath.fastestAllowedPeriod)
        }
    }

    /// Playhead position 0…1 within the current cycle.
    static func playheadPhase(time: Double, envelope: EnvelopeConfig) -> Double {
        let window = previewWindow(envelope)
        let p = (time / window).truncatingRemainder(dividingBy: 1.0)
        return p < 0 ? p + 1 : p
    }

    /// Canonical 16-point thumbnail for a shape — fixed representative
    /// parameters so the chip icon shows the shape's IDENTITY, not the
    /// current slider values.
    static func thumbnail(for shape: EnvelopeConfig.Shape) -> [Double] {
        let canonical = EnvelopeConfig(shape: shape, bpm: 60, depth: 100,
                                       attack: 30, decay: 60, dutyCycle: 40,
                                       minBrightness: 0, maxBrightness: 100)
        return curvePoints(canonical, samples: 16)
    }
}

// MARK: - EnvelopeStripView

/// StageKit-styled waveform well: the configured brightness curve with a
/// sweeping playhead dot. Pass the CONFIG value — reading it at the call
/// site registers observation exactly like PatternStripView's pattern param.
struct EnvelopeStripView: View {
    let envelope: EnvelopeConfig
    var accent: Color = HuePalette.amber
    var height: CGFloat = 52

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive

    private var isLive: Bool {
        !reduceMotion && isTabActive && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        // Depends only on the config — hoisted out of the 12fps tick, which
        // recomputed all 48 envelope evaluations every frame.
        let points = EnvelopeStripMath.curvePoints(envelope)
        return TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isLive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: HueRadius.sm)
                    .fill(StagePalette.raised)

                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let inset: CGFloat = 6

                    // The configured curve (static per frame).
                    Path { path in
                        for (i, v) in points.enumerated() {
                            let x = inset + (w - inset * 2) * CGFloat(i) / CGFloat(points.count - 1)
                            let y = h - inset - (h - inset * 2) * CGFloat(v)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(accent.opacity(0.85), lineWidth: 2)

                    // Sweeping playhead (live only).
                    if isLive {
                        let phase = EnvelopeStripMath.playheadPhase(time: t, envelope: envelope)
                        let level = LookPreviewMath.envelopeValue(
                            envelope, at: phase * EnvelopeStripMath.previewWindow(envelope))
                        let x = inset + (w - inset * 2) * CGFloat(phase)
                        let y = h - inset - (h - inset * 2) * CGFloat(min(1, max(0, level)))
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .position(x: x, y: y)
                            .shadow(color: accent.opacity(0.9), radius: 4)
                    }
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)   // decorative; the chips announce the shape
    }
}

// MARK: - MicLevelMeterView

/// Compact live bass/mid/treble + overall meter for mic reaction sources.
/// Polls the lock-guarded AudioAnalysisEngine.latestFeatures() — it NEVER
/// calls setDemand; when nothing holds a mic demand it honestly shows the
/// idle state instead.
struct MicLevelMeterView: View {
    /// reaction.threshold on its native 0-100 scale (tick on the level bar).
    var threshold: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive

    private var isLive: Bool {
        !reduceMotion && isTabActive && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isLive)) { _ in
            let features = AudioAnalysisEngine.latestFeatures()
            VStack(alignment: .leading, spacing: 5) {
                // The caption occupies its row UNCONDITIONALLY: features flip
                // silent/active as mic ownership changes, and a child that
                // inserts/removes itself at 12fps inside a ScrollView yanks
                // the user's scroll position (the composer "jump" bug).
                Text("MIC LISTENS WHEN THE LOOK RUNS")
                    .font(HueFont.stageTag)
                    .tracking(1.0)
                    .foregroundStyle(StagePalette.muted)
                    .opacity(features == .silent ? 1 : 0)
                meterBar(label: "LEVEL", value: Double(features.level),
                         tint: HuePalette.amber, threshold: threshold.map { $0 / 100.0 })
                HStack(spacing: 8) {
                    meterBar(label: "BASS", value: Double(features.bass),
                             tint: Color(hex: "#FF6B6B"), threshold: nil)
                    meterBar(label: "MID", value: Double(features.mid),
                             tint: Color(hex: "#40C9FF"), threshold: nil)
                    meterBar(label: "TREB", value: Double(features.treble),
                             tint: Color(hex: "#9BE29B"), threshold: nil)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func meterBar(label: String, value: Double, tint: Color,
                          threshold: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HueFont.stageTag)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, value)))))
                    if let threshold {
                        // The noise-gate's referent: levels left of the tick
                        // don't drive the reaction.
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * CGFloat(min(1, max(0, threshold))))
                    }
                }
            }
            .frame(height: 6)
        }
    }
}
