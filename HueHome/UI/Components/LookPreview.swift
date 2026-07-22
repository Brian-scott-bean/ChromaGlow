// LookPreview.swift
// ChromaGlow — data-driven look previews.
//
// Renders what a preset/effect ACTUALLY looks like — real palette colors,
// real motion pattern, real speed, real brightness envelope — instead of the
// id-keyed decorative art in StudioCardCanvas. One spec type feeds two views:
// LookPreviewStrip (the 8-segment signature strip, multi-color and
// speed-aware) and LookPreviewCanvas (the card-scale drifting-blob
// background).
//
// Perf/safety contract (same as PatternStripView / StudioCardCanvas):
//  - paused by Reduce Motion, \.isTabActive, and KeyboardState;
//  - off-screen renders a single static frame;
//  - preview motion is floored at 0.75s/cycle (≤1.33 flashes/sec) — the
//    photosensitivity clamp applies to PREVIEWS ONLY, never engine timing.

import SwiftUI

// MARK: - LookPreviewSpec

/// Everything a preview needs, as one Equatable value (cheap card diffing).
struct LookPreviewSpec: Equatable {
    var palette: PaletteConfig?          // nil → accent-tinted monochrome
    var pattern: MotionConfig.Pattern
    var speed: Double                    // 0-100, MotionConfig scale
    var envelope: EnvelopeConfig
    var accent: Color

    /// A composer preset previews its own four layers.
    init(preset: CompositionPreset) {
        self.palette  = preset.palette
        self.pattern  = preset.motion.pattern
        self.speed    = preset.motion.speed
        self.envelope = preset.envelope
        self.accent   = Color(hex: preset.accentColorHex)
    }

    /// Accent-only surfaces (engine deck cards, bridge scenes): signature
    /// pattern + accent tint, steady envelope.
    init(pattern: MotionConfig.Pattern, accent: Color, speed: Double = 40) {
        self.palette  = nil
        self.pattern  = pattern
        self.speed    = speed
        self.envelope = EnvelopeConfig(shape: .steady)
        self.accent   = accent
    }

    /// Matches the "+ Create" starter draft: warm default gradient, breathe.
    static let starter = LookPreviewSpec(
        palette: PaletteConfig(), pattern: .wave, speed: 40,
        envelope: EnvelopeConfig(), accent: HuePalette.amber
    )

    init(palette: PaletteConfig?, pattern: MotionConfig.Pattern, speed: Double,
         envelope: EnvelopeConfig, accent: Color) {
        self.palette = palette
        self.pattern = pattern
        self.speed = speed
        self.envelope = envelope
        self.accent = accent
    }
}

// MARK: - LookPreviewMath

/// Pure sampling — unit-tested, no SwiftUI state. All time-varying output is
/// a function of (spec, time), like StageStripMath.
enum LookPreviewMath {

    /// No preview cycle may complete faster than this (≤1.33Hz), regardless
    /// of the spec's real speed/bpm. The 3-flash tour floor precedent.
    static let fastestAllowedPeriod: Double = 0.75

    /// Preview-only flicker time scale — flicker's layered sines use absolute
    /// time (no bpm period to clamp), so previews run it at half speed to
    /// stay comfortably under the flash cap. Engine timing untouched.
    static let flickerPreviewTimeScale: Double = 0.5

    /// One strip segment's (palette phase, weight, envelope) at time t.
    static func sample(index: Int, count: Int, spec: LookPreviewSpec,
                       time: Double) -> (phase: Double, level: Double) {
        let position = count <= 1 ? 0.5 : Double(index) / Double(count - 1)
        let motion = MotionConfig(pattern: spec.pattern, speed: spec.speed)
        // Twinkle sparkles at period/8 (0.15s floor), so the plain period
        // floor doesn't bound its flash rate — floor it 8× harder.
        let floorPeriod = spec.pattern == .twinkle
            ? fastestAllowedPeriod * 8
            : fastestAllowedPeriod
        let clampedPeriod = max(motion.periodSeconds, floorPeriod)
        let (phase, weight) = motion.sample(
            position: position, radial: nil, angular: nil,
            lightIndex: index, time: time, overridePeriod: clampedPeriod
        )
        return (phase, min(1, max(0, weight * envelopeValue(spec.envelope, at: time))))
    }

    /// Envelope brightness with the preview-only rate clamp applied.
    static func envelopeValue(_ envelope: EnvelopeConfig, at time: Double) -> Double {
        let t: Double
        switch envelope.shape {
        case .flicker:
            t = time * flickerPreviewTimeScale
        case .steady:
            t = time
        case .breathe, .heartbeat, .pulse, .swell:
            // Slow time so the effective period never beats the floor.
            let period = 60.0 / max(1, envelope.bpm)
            t = period < fastestAllowedPeriod ? time * (period / fastestAllowedPeriod) : time
        }
        return min(1, max(0, envelope.value(at: t)))
    }

    /// Resolved segment color at a palette phase; accent when no palette.
    static func color(spec: LookPreviewSpec, phase: Double) -> Color {
        guard let palette = spec.palette else { return spec.accent }
        let xy = palette.color(at: phase)
        return HueColorUtils.color(fromX: xy.x, y: xy.y, brightness: 100)
    }

    /// Static fallback (Reduce Motion / not animated / off-screen): the real
    /// palette sampled evenly across the strip at full level.
    static func staticPhases(count: Int) -> [Double] {
        guard count > 1 else { return [0.5] }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }
}

// MARK: - LookPreviewStrip

/// The multi-color, speed-aware generalization of PatternStripView: each of
/// 8 capsules shows its own palette color and motion-weighted brightness.
struct LookPreviewStrip: View, Equatable {
    let spec: LookPreviewSpec
    var animated: Bool = true
    /// Frame-budget tier (StudioCardCanvas discipline): running cards tick
    /// at 12fps, at-rest "living" cards drift at 4fps — the canvas always
    /// had this split; the strip used to run 12fps at rest.
    var isRunning: Bool = false
    var height: CGFloat = 8

    private static let segmentCount = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive

    static func == (lhs: LookPreviewStrip, rhs: LookPreviewStrip) -> Bool {
        lhs.spec == rhs.spec && lhs.animated == rhs.animated
            && lhs.isRunning == rhs.isRunning && lhs.height == rhs.height
    }

    private var isLive: Bool {
        animated && !reduceMotion && isTabActive && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 12.0 : 0.25,
                                paused: !isLive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<Self.segmentCount, id: \.self) { i in
                    segment(index: i, time: t)
                }
            }
        }
        .accessibilityHidden(true)   // decorative signature; state announced elsewhere
    }

    @ViewBuilder
    private func segment(index i: Int, time t: Double) -> some View {
        if isLive {
            let s = LookPreviewMath.sample(index: i, count: Self.segmentCount,
                                           spec: spec, time: t)
            Capsule()
                .fill(LookPreviewMath.color(spec: spec, phase: s.phase))
                .frame(height: height)
                .opacity(0.25 + 0.75 * s.level)
        } else {
            let phases = LookPreviewMath.staticPhases(count: Self.segmentCount)
            Capsule()
                .fill(LookPreviewMath.color(spec: spec, phase: phases[i]))
                .frame(height: height)
                .opacity(0.55)
        }
    }
}

// MARK: - LookPreviewCanvas

/// Card-scale background: three soft radial blobs in the preset's real
/// colors, drifting at the (clamped) motion rate, breathing with the real
/// envelope. StudioCardCanvas's frame-budget discipline: idle 4fps, running
/// 12fps, single static frame off-screen or under a keyboard.
struct LookPreviewCanvas: View, Equatable {
    let spec: LookPreviewSpec
    var isRunning: Bool = false
    var isVisible: Bool = true

    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: LookPreviewCanvas, rhs: LookPreviewCanvas) -> Bool {
        lhs.spec == rhs.spec && lhs.isRunning == rhs.isRunning && lhs.isVisible == rhs.isVisible
    }

    var body: some View {
        if isVisible && isTabActive && !reduceMotion && !KeyboardState.shared.isKeyboardUp {
            TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 12.0 : 0.25)) { timeline in
                canvasContent(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvasContent(time: 0)
        }
    }

    private func canvasContent(time: Double) -> some View {
        Canvas { context, size in
            let intensity: Double = isRunning ? 0.55 : 0.30
            // Three blobs anchored across the palette (start/middle/end),
            // drifting on the clamped motion clock.
            let anchors: [Double] = [0.15, 0.5, 0.85]
            for (blob, anchor) in anchors.enumerated() {
                let s = LookPreviewMath.sample(index: blob, count: anchors.count,
                                               spec: spec, time: time)
                // Each blob stays near its palette anchor, nudged by the live
                // motion phase — blobs stay distinct in every pattern.
                let blend = (anchor * 0.7 + s.phase * 0.3).truncatingRemainder(dividingBy: 1.0)
                let color = LookPreviewMath.color(spec: spec, phase: blend)
                // Slow orbital drift, unique per blob.
                let drift = time / max(1.5, LookPreviewMath.fastestAllowedPeriod * 4)
                let angle = drift * .pi * 2 * (blob == 1 ? -0.5 : 1.0) + Double(blob) * 2.1
                let cx = size.width  * (anchor + 0.18 * cos(angle) * (blob == 1 ? 1 : 0.6))
                let cy = size.height * (0.45 + 0.25 * sin(angle))
                let radius = max(size.width, size.height) * 0.45
                let alpha = intensity * (0.35 + 0.65 * s.level)
                let rect = CGRect(x: cx - radius, y: cy - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(alpha), color.opacity(0)]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0, endRadius: radius
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
