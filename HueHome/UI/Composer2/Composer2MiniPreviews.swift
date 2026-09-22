// Composer2MiniPreviews.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Six small, cheap, state-driven previews for the Customize cards. Each is a
// pure function of (state, time) drawn under one shared clock that pauses
// when the card is off-screen, the tab is hidden, the keyboard is up or
// Reduce Motion is on. Card previews are floored at 0.75 s per cycle; the
// hero is the surface that mirrors the real engine timing.

import SwiftUI

// MARK: - Shared clock

struct Composer2MiniClock<Content: View>: View {
    let isEnabled: Bool
    let content: (_ time: Double, _ isLive: Bool) -> Content

    init(isEnabled: Bool, @ViewBuilder content: @escaping (_ time: Double, _ isLive: Bool) -> Content) {
        self.isEnabled = isEnabled
        self.content = content
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive
    @State private var visible = false

    static var frozenTime: Double { LookPreviewMath.frozenTime }

    private var isLive: Bool {
        visible && isEnabled && isTabActive && !reduceMotion && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isLive)) { context in
            content(isLive ? context.date.timeIntervalSinceReferenceDate : Composer2MiniClock.frozenTime, isLive)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

// MARK: - Palette

struct Composer2PalettePreview: View {
    let color: Composer2ColorSource

    var body: some View {
        let palette = Composer2CompiledPalette(color)
        Composer2MiniClock(isEnabled: color.drift > 0.05) { time, _ in
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { i in
                    let phase = Double(i) / 24 + time * 0.05 * color.drift
                    let xy = palette.sampleXY(phase)
                    Capsule()
                        .fill(Composer2Theme.solidColor(x: xy.x, y: xy.y))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 22)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    ForEach(0..<palette.stopCount, id: \.self) { i in
                        Circle().fill(Color.white.opacity(0.7)).frame(width: 4, height: 4)
                            .frame(maxWidth: .infinity)
                    }
                }
                .offset(y: 6)
            }
        }
    }
}

// MARK: - Motion

struct Composer2MotionPreview: View {
    let motion: Composer2Motion
    let accent: Color

    var body: some View {
        Composer2MiniClock(isEnabled: motion.kind != .static) { time, _ in
            let floorScale = min(1, motion.sanitizedPeriod / LookPreviewMath.fastestAllowedPeriod)
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    let s = motion.sample(slot: i, position: Double(i) / 7, cross: 0.5, time: time * floorScale, seed: 1)
                    let level = (0.5 + 0.5 * sin(2 * .pi * s.phase)) * s.weight
                    Capsule()
                        .fill(accent.opacity(0.18 + 0.82 * level))
                        .frame(maxWidth: .infinity)
                        .frame(height: 10 + 12 * level)
                }
            }
            .frame(height: 26, alignment: .center)
        }
    }
}

// MARK: - Rhythm

struct Composer2RhythmPreview: View {
    let rhythm: Composer2Rhythm
    let accent: Color

    var body: some View {
        Composer2MiniClock(isEnabled: rhythm.shape != .steady) { time, _ in
            Canvas { ctx, size in
                let period = max(LookPreviewMath.fastestAllowedPeriod, rhythm.sanitizedPeriod)
                var path = Path()
                let n = 48
                for i in 0...n {
                    let p = Double(i) / Double(n)
                    let v = rhythm.value(cyclePhase: p, time: p * period, slot: 0, seed: 1)
                    let pt = CGPoint(x: size.width * p, y: size.height * (1 - v * 0.9) - 1)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(accent.opacity(0.9)), lineWidth: 1.5)
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [accent.opacity(0.35), .clear]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                let phase = Composer2Math.frac(time / period)
                let v = rhythm.value(cyclePhase: phase, time: phase * period, slot: 0, seed: 1)
                let head = CGPoint(x: size.width * phase, y: size.height * (1 - v * 0.9) - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)), with: .color(.white))
            }
            .frame(height: 30)
        }
    }
}

// MARK: - Space

struct Composer2SpacePreview: View {
    let mask: Composer2LayerMask
    let motion: Composer2Motion
    let layout: Composer2SlotLayout
    let accent: Color
    /// The engine's own mask seed for this layer, so a random subset shows
    /// the lights that actually play.
    var maskSeed: UInt64 = 0

    var body: some View {
        let geometry = layout.geometry
        let weights = mask.weights(geometry: geometry, seed: maskSeed)
        Canvas { ctx, size in
            let count = layout.count
            if count == 0 {
                for i in 0..<15 {
                    let c = CGPoint(x: size.width * (0.1 + 0.2 * Double(i % 5)), y: size.height * (0.2 + 0.3 * Double(i / 5)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(accent.opacity(0.35)))
                }
            } else {
                for slot in layout.slots {
                    let x = slot.x ?? geometry.linearIndex[min(slot.index, geometry.linearIndex.count - 1)]
                    let z = slot.z ?? 0.5
                    let c = CGPoint(x: size.width * (0.08 + 0.84 * x), y: size.height * (0.15 + 0.7 * z))
                    let on = slot.index < weights.count ? weights[slot.index] : 1
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                             with: .color(accent.opacity(0.2 + 0.8 * on)))
                }
            }
            // Direction arrow.
            let degrees = motion.axisKind == .angle ? motion.angleDegrees : geometry.principalAngleDegrees
            let rad = degrees * .pi / 180
            let cx = size.width / 2, cy = size.height / 2
            let len = min(size.width, size.height) * 0.42
            let dir: Double = motion.reverse ? -1 : 1
            let tip = CGPoint(x: cx + dir * cos(rad) * len, y: cy + dir * sin(rad) * len * 0.6)
            let tail = CGPoint(x: cx - dir * cos(rad) * len, y: cy - dir * sin(rad) * len * 0.6)
            var arrow = Path()
            arrow.move(to: tail); arrow.addLine(to: tip)
            ctx.stroke(arrow, with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5)), with: .color(Color.white.opacity(0.7)))
            if mask.kind == .region || motion.mirror {
                var mid = Path()
                mid.move(to: CGPoint(x: cx, y: 0)); mid.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(mid, with: .color(Color.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

// MARK: - Audio

struct Composer2AudioPreview: View {
    let audio: Composer2AudioModulation
    let accent: Color

    var body: some View {
        if !audio.isActive {
            HStack {
                Text("Off").font(HueFont.stageStatus).foregroundStyle(Composer2Theme.muted)
                Spacer()
            }
            .frame(height: 30)
        } else {
            Composer2MiniClock(isEnabled: true) { time, isLive in
                let features = AudioAnalysisEngine.latestFeatures()
                let listening = AudioAnalysisEngine.shared.hasActiveDemand && features.timestamp > 0
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<12, id: \.self) { i in
                        let level = Composer2AudioPreview.level(bar: i, features: features, listening: listening, time: time, audio: audio)
                        Capsule()
                            .fill(accent.opacity(0.3 + 0.7 * level))
                            .frame(maxWidth: .infinity)
                            .frame(height: 4 + 24 * level)
                    }
                }
                .frame(height: 30, alignment: .bottom)
                .overlay(alignment: .topTrailing) {
                    Text(listening ? Composer2Copy.micListening : Composer2Copy.micWaiting)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Composer2Theme.muted)
                }
            }
        }
    }

    static func level(bar: Int, features: AudioFeatures, listening: Bool, time: Double, audio: Composer2AudioModulation) -> Double {
        if listening {
            let band: Float
            switch bar {
            case 0..<4: band = features.bass
            case 4..<8: band = features.mid
            default: band = features.treble
            }
            let blend = Double(band) * 0.7 + Double(features.level) * 0.3
            return Composer2Math.clamp01(audio.shaped(blend))
        }
        let phase = time * 1.2 + Double(bar) * 0.45
        return 0.15 + 0.35 * (0.5 + 0.5 * sin(phase))
    }
}

// MARK: - Variation

struct Composer2VariationPreview: View {
    let variation: Composer2Variation
    let accent: Color

    var body: some View {
        Composer2MiniClock(isEnabled: variation.evolveRate > 0 && variation.amount > 0) { time, _ in
            Canvas { ctx, size in
                let amount = Composer2Math.clamp01(variation.amount)
                for i in 0..<9 {
                    let gx = Double(i % 3), gy = Double(i / 3)
                    let baseX = size.width * (0.2 + 0.3 * gx)
                    let baseY = size.height * (0.2 + 0.3 * gy)
                    let jx: Double, jy: Double
                    if variation.evolveRate > 0 {
                        jx = Composer2Noise.value1D(time * 0.4 + Double(i) * 3.1, seed: 11) - 0.5
                        jy = Composer2Noise.value1D(time * 0.4 + Double(i) * 5.7, seed: 12) - 0.5
                    } else {
                        jx = Composer2Hash.unit(7, i, 0, salt: 1) - 0.5
                        jy = Composer2Hash.unit(7, i, 0, salt: 2) - 0.5
                    }
                    let x = baseX + jx * size.width * 0.28 * amount
                    let y = baseY + jy * size.height * 0.5 * amount
                    let r = 2.5 + 2 * amount * Composer2Hash.unit(7, i, 0, salt: 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(accent.opacity(0.45 + 0.55 * amount)))
                }
            }
            .frame(height: 30)
        }
    }
}
