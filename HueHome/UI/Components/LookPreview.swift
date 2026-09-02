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
//  - only the selected/running card animates; idle cards render ONE static
//    representative frame (LookPreviewMath.frozenTime) at reduced prominence,
//    so a deck of visible cards costs no animation work and reads as quietly
//    as the Effects/Live cards beside it;
//  - paused by Reduce Motion, \.isTabActive, and KeyboardState (same frame);
//  - off-screen renders that same single static frame;
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

    /// Swatch fallback (`animated == false`): the real palette sampled evenly
    /// across the strip at full level.
    static func staticPhases(count: Int) -> [Double] {
        guard count > 1 else { return [0.5] }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }

    // MARK: Idle vs running rendering

    /// Idle (unselected) previews render ONE static frame sampled at this
    /// deterministic time instead of ticking a clock. Quarter-phase of the
    /// default 60 BPM breathe envelope, so the default look freezes at
    /// mid-brightness rather than the t = 0 peak every card would share.
    static let frozenTime: Double = 4.25

    /// Canvas blob alpha scale. Running keeps its historic value; idle sits
    /// inside StudioCardCanvas's at-rest band (0.04–0.175 peak alpha).
    static func canvasIntensity(isRunning: Bool) -> Double {
        isRunning ? 0.55 : 0.10
    }

    /// Canvas blob radius as a fraction of the card's long edge. Running
    /// keeps its historic full-bleed value; idle matches drawOpal's 0.35.
    static func canvasRadiusScale(isRunning: Bool) -> Double {
        isRunning ? 0.45 : 0.35
    }

    /// Strip segment opacity for a motion-weighted level. Running keeps the
    /// historic 0.25…1.0 swing; idle narrows it to 0.35…0.60 so the palette
    /// stays legible without the shimmer dominating the card.
    static func stripOpacity(level: Double, isRunning: Bool) -> Double {
        let l = min(1, max(0, level))
        return isRunning ? 0.25 + 0.75 * l : 0.35 + 0.25 * l
    }
}

// MARK: - LookPreviewStrip

/// The multi-color, speed-aware generalization of PatternStripView: each of
/// 8 capsules shows its own palette color and motion-weighted brightness.
struct LookPreviewStrip: View, Equatable {
    let spec: LookPreviewSpec
    /// `false` = swatch mode: an even, static palette spread (scene chips).
    var animated: Bool = true
    /// Only the running card animates (12fps). An animated-but-idle strip
    /// shows one static representative frame of its real motion signature at
    /// idle prominence — no clock, no shimmer — until it becomes running.
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
        animated && isRunning && !reduceMotion && isTabActive
            && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        // The TimelineView stays mounted in every state (paused when not
        // live) so idle↔running never swaps the subtree or resets identity.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0,
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

    private func segment(index i: Int, time t: Double) -> some View {
        let frame = segmentFrame(index: i, time: t)
        // One Capsule for every state: only its colour/opacity values change.
        return Capsule()
            .fill(frame.color)
            .frame(height: height)
            .opacity(frame.opacity)
    }

    private func segmentFrame(index i: Int, time t: Double) -> (color: Color, opacity: Double) {
        if isLive {
            let s = LookPreviewMath.sample(index: i, count: Self.segmentCount,
                                           spec: spec, time: t)
            return (LookPreviewMath.color(spec: spec, phase: s.phase),
                    LookPreviewMath.stripOpacity(level: s.level, isRunning: true))
        } else if animated {
            // Idle, Reduce Motion, off-tab, or under a keyboard: one
            // deterministic representative frame of the real signature.
            let s = LookPreviewMath.sample(index: i, count: Self.segmentCount,
                                           spec: spec, time: LookPreviewMath.frozenTime)
            return (LookPreviewMath.color(spec: spec, phase: s.phase),
                    LookPreviewMath.stripOpacity(level: s.level, isRunning: isRunning))
        } else {
            let phases = LookPreviewMath.staticPhases(count: Self.segmentCount)
            return (LookPreviewMath.color(spec: spec, phase: phases[i]), 0.55)
        }
    }
}

// MARK: - LookPreviewCanvas

/// Card-scale background: three soft radial blobs in the preset's real
/// colors, drifting at the (clamped) motion rate, breathing with the real
/// envelope. Only the running card animates (12fps); idle cards render one
/// static representative frame at reduced intensity/radius — the same frame
/// used off-screen, under Reduce Motion, and under a keyboard.
struct LookPreviewCanvas: View, Equatable {
    let spec: LookPreviewSpec
    var isRunning: Bool = false
    var isVisible: Bool = true

    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: LookPreviewCanvas, rhs: LookPreviewCanvas) -> Bool {
        lhs.spec == rhs.spec && lhs.isRunning == rhs.isRunning && lhs.isVisible == rhs.isVisible
    }

    private var isLive: Bool {
        isRunning && isVisible && isTabActive && !reduceMotion
            && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        // Stays mounted (paused when not live) so idle↔running never swaps
        // the subtree; the static frame is deterministic, never t = 0.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isLive)) { timeline in
            canvasContent(time: isLive
                          ? timeline.date.timeIntervalSinceReferenceDate
                          : LookPreviewMath.frozenTime)
        }
    }

    private func canvasContent(time: Double) -> some View {
        Canvas { context, size in
            let intensity = LookPreviewMath.canvasIntensity(isRunning: isRunning)
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
                let radius = max(size.width, size.height)
                    * LookPreviewMath.canvasRadiusScale(isRunning: isRunning)
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
