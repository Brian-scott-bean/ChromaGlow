// LuminousKit.swift
// ChromaGlow — the v2.2 "Luminous" design language, shared by every screen.
//
// The idea in one line: the app is a dark room, and the only light in it is
// the light you control. Surfaces are deep glass; whatever a card stands for
// (a room, a scene, a look) glows in that thing's own colour; the brand amber
// is kept for actions. Everything springs under the finger, respects Reduce
// Motion, and pauses its clocks when its tab is hidden (`\.isTabActive`).
//
// Components:
//   • `LuminousPalette`        — the tokens.
//   • `.luminousPanel(…)`      — the glass card every surface is built on.
//   • `LuminousPressStyle`     — the springy press for any tappable card.
//   • `LuminousAmbience`       — a slow glow behind a screen, tinted by colours.
//   • `LuminousSectionHeader`  — rounded, bold section titles with an action.
//   • `LuminousIconBadge`      — a glowing icon disc.

import SwiftUI

// MARK: - Tokens

enum LuminousPalette {
    /// The room with the lights off.
    static let void = Color(hex: "#05060C")
    /// A breath of night-blue under the void.
    static let night = Color(hex: "#0D1122")
    static let ink = Color(hex: "#F4F2EC")
    static let inkSecondary = Color.white.opacity(0.62)
    static let inkTertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)
    /// The brand accent, as a gradient for primary actions.
    static let amber = HuePalette.amber
    static let amberDeep = HuePalette.amberDeep
    static var amberGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: "#FFD36B"), HuePalette.amber, HuePalette.amberDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let live = HuePalette.Noir.success

    static let panelRadius: CGFloat = 22
    static let cardRadius: CGFloat = 20
}

// MARK: - Panel

struct LuminousPanel: ViewModifier {
    var radius: CGFloat = LuminousPalette.panelRadius
    /// The colour this panel stands for; nil for a neutral panel.
    var glow: Color? = nil
    /// 0…1 how lit the panel is (a room at 30 % glows less than at 100 %).
    var glowStrength: Double = 1
    var raised: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let strength = max(0, min(1, glowStrength))
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial.opacity(0.5))
                    shape.fill(Color.white.opacity(raised ? 0.085 : 0.055))
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                              startPoint: .top, endPoint: .center))
                    if let glow {
                        shape.fill(RadialGradient(colors: [glow.opacity(0.30 * strength), glow.opacity(0.06 * strength), .clear],
                                                  center: .topLeading, startRadius: 0, endRadius: 240))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [(glow ?? .white).opacity(glow == nil ? 0.16 : 0.55 * strength + 0.12),
                                            (glow ?? .white).opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            )
            .clipShape(shape)
            .shadow(color: glow.map { $0.opacity(0.28 * strength) } ?? .black.opacity(0.3),
                    radius: glow == nil ? 12 : 16, y: glow == nil ? 6 : 4)
    }
}

extension View {
    /// The glass card every Luminous surface is built on.
    func luminousPanel(radius: CGFloat = LuminousPalette.panelRadius, glow: Color? = nil,
                       glowStrength: Double = 1, raised: Bool = false) -> some View {
        modifier(LuminousPanel(radius: radius, glow: glow, glowStrength: glowStrength, raised: raised))
    }
}

// MARK: - Press

/// A soft spring on press — every card answers the finger.
struct LuminousPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .brightness(configuration.isPressed ? 0.05 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.64), value: configuration.isPressed)
    }
}

// MARK: - Ambience

/// Three slow pools of light behind a screen, tinted by `colors` — on Home,
/// the colours the lights are showing right now. One Canvas, a few frames a
/// second, paused off-screen or under Reduce Motion.
struct LuminousAmbience: View {
    let colors: [Color]
    var intensity: Double = 1

    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var ticking: Bool { isTabActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: !ticking)) { timeline in
            Canvas(rendersAsynchronously: true) { ctx, size in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                LuminousAmbience.draw(in: &ctx, size: size, colors: colors, intensity: intensity, time: t)
            }
        }
        .background(LuminousPalette.void)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, colors: [Color], intensity: Double, time: Double) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [LuminousPalette.void, LuminousPalette.night.opacity(0.7), LuminousPalette.void]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        guard !colors.isEmpty else { return }
        var light = ctx
        light.blendMode = .plusLighter
        let anchors: [(x: Double, y: Double, r: Double, speed: Double)] = [
            (0.12, 0.05, 0.9, 0.019), (0.92, 0.38, 0.8, 0.015), (0.35, 0.92, 0.95, 0.012)
        ]
        let k = max(0, min(1.5, intensity))
        for (i, a) in anchors.enumerated() {
            let color = colors[i % colors.count]
            let dx = sin(time * a.speed * 2 * .pi + Double(i) * 2.1) * 0.07
            let dy = cos(time * a.speed * 1.7 * .pi + Double(i) * 1.3) * 0.05
            let c = CGPoint(x: w * (a.x + dx), y: h * (a.y + dy))
            let r = max(w, h) * a.r * 0.6
            light.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.2 * k), color.opacity(0.06 * k), .clear]),
                                             center: c, startRadius: 0, endRadius: r))
        }
    }
}

// MARK: - Section header

struct LuminousSectionHeader<Trailing: View>: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.amber
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(LuminousPalette.ink)
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension LuminousSectionHeader where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, tint: Color = LuminousPalette.amber) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.trailing = { EmptyView() }
    }
}

// MARK: - Icon badge

/// A glowing disc behind an SF Symbol — the icon of a room, scene or setting.
struct LuminousIconBadge: View {
    let symbol: String
    var tint: Color = LuminousPalette.amber
    var size: CGFloat = 36
    var lit: Bool = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(lit ? tint : LuminousPalette.inkTertiary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(colors: [tint.opacity(lit ? 0.32 : 0.08), tint.opacity(lit ? 0.08 : 0.02)],
                                             center: .center, startRadius: 0, endRadius: size * 0.6))
            )
            .overlay(Circle().strokeBorder(tint.opacity(lit ? 0.35 : 0.1), lineWidth: 1))
            .shadow(color: lit ? tint.opacity(0.45) : .clear, radius: 8)
            .accessibilityHidden(true)
    }
}
