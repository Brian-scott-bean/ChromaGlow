// Composer2Ambience.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// The screen behind the instrument glows in the colours of the look being
// composed: three slow pools of light drift behind the glass, so switching
// from Thunderstorm to Jack-o'-Lantern changes the whole room on screen.
// Cheap by construction — radial gradients on one Canvas at a few frames a
// second, paused when hidden or under Reduce Motion.

import SwiftUI

struct Composer2Ambience: View {
    let colors: [Color]

    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var ticking: Bool { isTabActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: !ticking)) { timeline in
            Canvas(rendersAsynchronously: true) { ctx, size in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                Composer2Ambience.draw(in: &ctx, size: size, colors: colors, time: t)
            }
        }
        .background(Composer2Theme.void)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: colors.count)
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, colors: [Color], time: Double) {
        let w = size.width, h = size.height
        let palette = colors.isEmpty ? [Composer2Theme.cyan, Composer2Theme.violet] : colors
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Composer2Theme.void, Composer2Theme.navy.opacity(0.6), Composer2Theme.void]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        var light = ctx
        light.blendMode = .plusLighter
        let anchors: [(x: Double, y: Double, r: Double, speed: Double)] = [
            (0.15, 0.08, 0.95, 0.021), (0.9, 0.42, 0.85, 0.017), (0.3, 0.88, 1.0, 0.013)
        ]
        for (i, a) in anchors.enumerated() {
            let color = palette[i % palette.count]
            let dx = sin(time * a.speed * 2 * .pi + Double(i) * 2.1) * 0.08
            let dy = cos(time * a.speed * 1.7 * .pi + Double(i) * 1.3) * 0.05
            let center = CGPoint(x: w * (a.x + dx), y: h * (a.y + dy))
            let radius = max(w, h) * a.r * 0.62
            light.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0.07), .clear]),
                                             center: center, startRadius: 0, endRadius: radius))
        }
    }
}
