// Composer2LookCard.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// One look in the library: a tiny live stage — the real engine, playing the
// real composition on seven lights — over a wash of the look's colours, its
// name and one line about it. Cards animate only while they are on screen,
// the tab is visible, and Reduce Motion is off; otherwise they hold a still.

import SwiftUI

struct Composer2LookCard: View {
    enum Style { case grid, feature }

    let composition: Composer2Composition
    var symbol: String = "sparkles"
    var accent: Color = Composer2Theme.cyan
    var isNew: Bool = false
    var isSelected: Bool = false
    var isPlaying: Bool = false
    var style: Style = .grid
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticManager.shared.selection()
            action()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Composer2MiniStage(composition: composition, lights: style == .feature ? 9 : 7)
                        .frame(height: style == .feature ? 150 : 92)
                    HStack(spacing: 6) {
                        if isPlaying {
                            Label("Playing", systemImage: "waveform")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Composer2Theme.void)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 22)
                                .background(Capsule().fill(Composer2Theme.live))
                        } else if isNew {
                            Text("NEW")
                                .font(.caption2.weight(.heavy))
                                .tracking(1)
                                .foregroundStyle(Composer2Theme.void)
                                .padding(.horizontal, 7)
                                .frame(minHeight: 20)
                                .background(Capsule().fill(accent))
                        }
                    }
                    .padding(8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                        Text(composition.name)
                            .font(.system(style == .feature ? .headline : .subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Composer2Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text(composition.subtitle.isEmpty ? " " : composition.subtitle)
                        .font(.caption)
                        .foregroundStyle(Composer2Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                ZStack {
                    Composer2Theme.void
                    Composer2PaletteWash(colors: Composer2Theme.swatches(of: composition, max: 3))
                        .opacity(0.16)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? accent : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? accent.opacity(0.45) : .black.opacity(0.35), radius: isSelected ? 16 : 10, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(Composer2PressStyle(scale: 0.97))
        .accessibilityLabel("\(composition.name). \(composition.subtitle)")
        .accessibilityHint(isSelected ? "Selected" : "Double tap to try this look")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Mini stage

/// A small live stage: the composition on `lights` lights in an arc,
/// evaluated by the real engine at a gentle frame rate.
struct Composer2MiniStage: View {
    let composition: Composer2Composition
    var lights: Int = 7

    @State private var output: Composer2LiveOutput?
    @State private var visible = false
    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ticking: Bool { visible && isTabActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 14.0, paused: !ticking)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, size in
                let out = output ?? Composer2MiniStage.makeOutput(composition, lights: lights)
                if out.composition != composition { out.composition = composition }
                // Each card keeps its own time base so the grid never pulses in unison.
                let offset = Double(Composer2Hash.seed(from: composition.id) % 997)
                let t = reduceMotion ? 3.0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) + offset
                let frames = out.evaluate(time: t)
                Composer2MiniStage.draw(in: &ctx, size: size, frames: frames)
            }
        }
        .background(Composer2Theme.void.opacity(0.4))
        .onAppear {
            if output == nil { output = Composer2MiniStage.makeOutput(composition, lights: lights) }
            visible = true
        }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }

    static func makeOutput(_ composition: Composer2Composition, lights: Int) -> Composer2LiveOutput {
        let out = Composer2LiveOutput(composition: composition)
        var points: [(x: Double, z: Double)] = []
        for i in 0..<lights {
            let u = lights > 1 ? Double(i) / Double(lights - 1) : 0.5
            points.append((x: u, z: 0.5 - 0.35 * sin(.pi * u)))
        }
        out.setPreviewGeometry(Composer2SlotGeometry(points: points))
        return out
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, frames: [Composer2Frame]) {
        let w = size.width, h = size.height
        let n = frames.count
        guard n > 0 else { return }
        var light = ctx
        light.blendMode = .plusLighter
        let r = min(h * 0.09, w / CGFloat(n) * 0.22)
        for (i, f) in frames.enumerated() {
            let u = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0.5
            let p = CGPoint(x: w * (0.1 + 0.8 * u), y: h * (0.62 - 0.3 * sin(.pi * u)))
            let b = CGFloat(Composer2Math.clamp01(f.brightness))
            let color = Composer2Theme.solidColor(x: f.x, y: f.y)
            let wash = r * 7
            light.fill(Path(ellipseIn: CGRect(x: p.x - wash, y: p.y - wash, width: wash * 2, height: wash * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.28 * b), .clear]),
                                             center: p, startRadius: 0, endRadius: wash))
            let halo = r * 2.6
            light.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.7 * b), .clear]),
                                             center: p, startRadius: 0, endRadius: halo))
            light.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [Color.white.opacity(0.9 * b), color.opacity(0.35 + 0.65 * b)]),
                                             center: p, startRadius: 0, endRadius: r))
        }
    }
}
