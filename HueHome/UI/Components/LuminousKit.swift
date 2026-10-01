// LuminousKit.swift
// ChromaGlow — the Luminous design language, app-wide.
//
// The idea in one line: the app is a dark room, and the only light in it is
// the light you control. This kit is the Composer's look and feel, lifted out
// of the Composer so every screen speaks it:
//
//   • Surfaces are deep glass over the void. Chrome never carries colour.
//   • Colour belongs to light: a room glows in the colours its lamps are
//     showing, a scene in its palette, a look in its own frames.
//   • One action colour — the signal gradient (cyan → violet, a slice of the
//     icon's spectrum) — marks the thing that sends light out. Live is green.
//     Amber means "edited / needs attention". Red only ever means destroy.
//   • Type is rounded and heavy for names, plain for sentences.
//   • Everything springs under the finger, respects Reduce Motion, and
//     pauses its clocks when its tab is hidden (`\.isTabActive`).
//
// Components (see docs/ios/luminous-app-redesign/README.md for usage):
//   Tokens       LuminousPalette, LuminousType
//   Surfaces     LuminousAmbience, .luminousGlass, .luminousPanel, .luminousStageFrame
//   Headings     LuminousEyebrow, LuminousSectionHeader, LuminousScreenTitle
//   Controls     LuminousPressStyle, LuminousRoundButton, LuminousCapsuleLabel,
//                LuminousStateChip, LuminousChip, LuminousSegmented,
//                LuminousGlowSlider, LuminousPrimaryButton, LuminousSecondaryButton,
//                LuminousPowerButton, LuminousIconBadge, LuminousLiveBadge,
//                LuminousFactBadge
//   Lists        LuminousGroup, LuminousRow, LuminousRowDivider, LuminousChevron
//   Input        LuminousTextField
//   Feedback     LuminousNotice, LuminousEmptyState
//   Light        LuminousLight (real lamp state → screen colour and stage frames)

import SwiftUI

// MARK: - Tokens

enum LuminousPalette {
    /// The room with the lights off.
    static let void = Color(hex: "#04050B")
    /// A breath of night-blue under the void.
    static let night = Color(hex: "#0C1024")
    static let ink = Color(hex: "#F2F0EA")
    static let inkSecondary = Color(hex: "#8F8C99")
    static let inkTertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.18)
    static let glass = Color.white.opacity(0.055)
    static let glassRaised = Color.white.opacity(0.09)

    /// The signal: what sends light out (Go Live, Activate, primary actions).
    static let cyan = Color(hex: "#4FE3FF")
    static let violet = Color(hex: "#9B7BFF")
    static let magenta = Color(hex: "#FF5CC8")
    static var signalGradient: LinearGradient {
        LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var signalGradientHorizontal: LinearGradient {
        LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
    }
    /// The icon's spectrum — used sparingly (the brand mark, empty states).
    static var spectrum: AngularGradient {
        AngularGradient(colors: [Color(hex: "#FFD24A"), Color(hex: "#FF7A3D"), Color(hex: "#FF3D8B"),
                                 Color(hex: "#9B5CFF"), Color(hex: "#3D8BFF"), Color(hex: "#3DFFB0"),
                                 Color(hex: "#FFD24A")],
                        center: .center)
    }

    /// Something is playing on real lights.
    static let live = Color(hex: "#30D158")
    static var liveGradient: LinearGradient {
        LinearGradient(colors: [live, Color(hex: "#1FB5A0")], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Edited, attention, warm.
    static let amber = Color(hex: "#FFB547")
    /// The person's own creations.
    static let lime = Color(hex: "#B8FF6B")
    /// Only for destroying things.
    static let danger = Color(hex: "#FF5A52")

    static let panelRadius: CGFloat = 22
    static let cardRadius: CGFloat = 20
    static let stageRadius: CGFloat = 28
}

/// Type styles. Names are rounded and heavy; sentences are plain. All are
/// Dynamic-Type relative.
enum LuminousType {
    /// A screen's own name ("Living Room", "Scenes").
    static let display = Font.system(.largeTitle, design: .rounded).weight(.heavy)
    /// A section's name.
    static let title = Font.system(.title3, design: .rounded).weight(.bold)
    /// A card's name.
    static let cardTitle = Font.system(.headline, design: .rounded).weight(.bold)
    static let cardTitleSmall = Font.system(.subheadline, design: .rounded).weight(.bold)
    static let body = Font.subheadline
    static let bodyStrong = Font.subheadline.weight(.semibold)
    static let caption = Font.caption
    static let captionStrong = Font.caption.weight(.semibold)
    /// Small heavy tracked caps over a group ("SHOWPIECES").
    static let eyebrow = Font.caption.weight(.heavy)
    /// Numbers that change under the finger.
    static let value = Font.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit()
    static let bigValue = Font.system(.title2, design: .rounded).weight(.heavy).monospacedDigit()
}

// MARK: - Ambience

/// Three slow pools of light behind a screen, tinted by `colors` — on Home
/// the colours the lights are showing right now, in a room its lamps, in
/// Scenes the favourites. One Canvas, a few frames a second, paused when the
/// tab is hidden, the app is in the background, or Reduce Motion is on.
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
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, colors: [Color], intensity: Double, time: Double) {
        let w = size.width, h = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [LuminousPalette.void, LuminousPalette.night.opacity(0.6), LuminousPalette.void]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        guard !colors.isEmpty else { return }
        var light = ctx
        light.blendMode = .plusLighter
        let anchors: [(x: Double, y: Double, r: Double, speed: Double)] = [
            (0.15, 0.08, 0.95, 0.021), (0.9, 0.42, 0.85, 0.017), (0.3, 0.88, 1.0, 0.013)
        ]
        let k = max(0, min(1.5, intensity))
        for (i, a) in anchors.enumerated() {
            let color = colors[i % colors.count]
            let dx = sin(time * a.speed * 2 * .pi + Double(i) * 2.1) * 0.08
            let dy = cos(time * a.speed * 1.7 * .pi + Double(i) * 1.3) * 0.05
            let c = CGPoint(x: w * (a.x + dx), y: h * (a.y + dy))
            let r = max(w, h) * a.r * 0.62
            light.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.22 * k), color.opacity(0.07 * k), .clear]),
                                             center: c, startRadius: 0, endRadius: r))
        }
    }
}

// MARK: - Glass

/// The glass card every surface is built on — the Composer's panel.
/// `accent` + `selected` light the edge and the top-left corner.
struct LuminousGlass: ViewModifier {
    var radius: CGFloat = LuminousPalette.panelRadius
    var accent: Color? = nil
    var selected: Bool = false
    var raised: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = selected ? (accent ?? LuminousPalette.cyan) : Color.white
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial.opacity(0.45))
                    shape.fill(raised ? LuminousPalette.glassRaised : LuminousPalette.glass)
                    shape.fill(LinearGradient(colors: [Color.white.opacity(raised ? 0.07 : 0.05), .clear],
                                              startPoint: .top, endPoint: .center))
                    if let accent, selected {
                        shape.fill(RadialGradient(colors: [accent.opacity(0.16), .clear],
                                                  center: .topLeading, startRadius: 0, endRadius: 260))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [edge.opacity(selected ? 0.7 : 0.16), edge.opacity(selected ? 0.25 : 0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: selected ? 1.2 : 1)
            )
            .clipShape(shape)
            .shadow(color: selected ? (accent ?? LuminousPalette.cyan).opacity(0.3) : .black.opacity(0.25),
                    radius: selected ? 20 : 12, y: selected ? 0 : 6)
    }
}

/// A panel lit by what it stands for: a room at 30 % glows less than at 100 %.
struct LuminousPanel: ViewModifier {
    var radius: CGFloat = LuminousPalette.panelRadius
    /// The colour this panel stands for; nil for a neutral panel.
    var glow: Color? = nil
    /// 0…1 how lit the panel is.
    var glowStrength: Double = 1
    var raised: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let strength = max(0, min(1, glowStrength))
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial.opacity(0.45))
                    shape.fill(raised ? LuminousPalette.glassRaised : LuminousPalette.glass)
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.06), .clear],
                                              startPoint: .top, endPoint: .center))
                    if let glow {
                        shape.fill(RadialGradient(colors: [glow.opacity(0.26 * strength), glow.opacity(0.05 * strength), .clear],
                                                  center: .topLeading, startRadius: 0, endRadius: 260))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [(glow ?? .white).opacity(glow == nil ? 0.16 : 0.45 * strength + 0.12),
                                            (glow ?? .white).opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            )
            .clipShape(shape)
            .shadow(color: glow.map { $0.opacity(0.22 * strength) } ?? .black.opacity(0.25),
                    radius: glow == nil ? 12 : 16, y: glow == nil ? 6 : 4)
    }
}

/// The frame around a stage (a room drawn as light): the void, a deep
/// rounded edge that turns green while something plays there, a long shadow.
struct LuminousStageFrame: ViewModifier {
    var radius: CGFloat = LuminousPalette.stageRadius
    var isLive: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(LuminousPalette.void)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [(isLive ? LuminousPalette.live : Color.white).opacity(isLive ? 0.45 : 0.16),
                                                           Color.white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

extension View {
    /// The Composer's glass card.
    func luminousGlass(radius: CGFloat = LuminousPalette.panelRadius, accent: Color? = nil,
                       selected: Bool = false, raised: Bool = false) -> some View {
        modifier(LuminousGlass(radius: radius, accent: accent, selected: selected, raised: raised))
    }

    /// A glass card lit by the colour it stands for.
    func luminousPanel(radius: CGFloat = LuminousPalette.panelRadius, glow: Color? = nil,
                       glowStrength: Double = 1, raised: Bool = false) -> some View {
        modifier(LuminousPanel(radius: radius, glow: glow, glowStrength: glowStrength, raised: raised))
    }

    /// The frame for a stage.
    func luminousStageFrame(radius: CGFloat = LuminousPalette.stageRadius, isLive: Bool = false) -> some View {
        modifier(LuminousStageFrame(radius: radius, isLive: isLive))
    }

    /// A pushed screen's navigation bar: transparent over the ambience, the
    /// title carried in the content, the system back button kept so the edge
    /// swipe keeps working.
    func luminousNavigationChrome(title: String = "") -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// A sheet in the Luminous language: the void behind it, a grabber,
    /// dark scheme.
    func luminousSheet() -> some View {
        self
            .presentationBackground(LuminousPalette.void)
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
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

// MARK: - Headings

/// Small heavy tracked caps over a group.
struct LuminousEyebrow: View {
    let text: String
    var tint: Color = LuminousPalette.inkSecondary

    var body: some View {
        Text(text.uppercased())
            .font(LuminousType.eyebrow)
            .tracking(1.4)
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section's title, an optional sentence under it, and an action.
struct LuminousSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = LuminousPalette.inkSecondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(LuminousType.title)
                        .foregroundStyle(LuminousPalette.ink)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension LuminousSectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = LuminousPalette.inkSecondary) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = { EmptyView() }
    }
}

/// A screen's own name, the way the Composer names a look: an eyebrow line
/// with an icon in its colour, the name rounded and heavy, one sentence.
struct LuminousScreenTitle: View {
    let title: String
    var eyebrow: String? = nil
    var eyebrowSymbol: String? = nil
    var eyebrowTint: Color = LuminousPalette.cyan
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                HStack(spacing: 6) {
                    if let eyebrowSymbol {
                        Image(systemName: eyebrowSymbol).font(.caption.weight(.bold))
                    }
                    Text(eyebrow).font(.caption.weight(.bold))
                }
                .foregroundStyle(eyebrowTint)
                .lineLimit(1)
            }
            Text(title)
                .font(LuminousType.display)
                .foregroundStyle(LinearGradient(colors: [LuminousPalette.ink, LuminousPalette.ink.opacity(0.78)],
                                                startPoint: .top, endPoint: .bottom))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Round buttons, capsules, chips

/// The round glass button of every header (close, add, search, more).
struct LuminousRoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    var tint: Color = LuminousPalette.ink
    var filled: Bool = false
    var badge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LuminousRoundGlyph(symbol: symbol, size: size, tint: tint, filled: filled, badge: badge)
        }
        .buttonStyle(LuminousPressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// The look of a round glass button, for use as a Menu label.
struct LuminousRoundGlyph: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = LuminousPalette.ink
    var filled: Bool = false
    var badge: Bool = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(filled ? LuminousPalette.void : tint)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial)))
            .overlay(Circle().strokeBorder(Color.white.opacity(filled ? 0 : 0.14), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(LuminousPalette.amber).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(LuminousPalette.void, lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                }
            }
            .shadow(color: filled ? tint.opacity(0.5) : .black.opacity(0.3), radius: filled ? 12 : 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
    }
}

/// A capsule label — the Composer's room picker. Put it inside a Menu or Button.
struct LuminousCapsuleLabel: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.cyan
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
        }
        .foregroundStyle(LuminousPalette.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
}

/// Dot + words: connection, how many rooms are on, LIVE.
struct LuminousStateChip: View {
    let text: String
    var dot: Color = LuminousPalette.inkSecondary
    var glowing: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .shadow(color: glowing ? dot : .clear, radius: 4)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A filter or choice chip. Selected chips fill with their accent and glow.
struct LuminousChip: View {
    let title: String
    var symbol: String? = nil
    var selected: Bool = false
    var accent: Color = LuminousPalette.cyan
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticManager.shared.selection()
            action()
        }) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(selected ? LuminousPalette.void : LuminousPalette.ink.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(Capsule().fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.07))))
            .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.9) : Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: selected ? accent.opacity(0.5) : .clear, radius: 10)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(LuminousPressStyle(scale: 0.96))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The Composer's Looks · Tune · Layers selector, for any set of choices.
/// The selected segment carries a glow that glides between them.
struct LuminousSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var symbol: (Option) -> String? = { _ in nil }
    var accessibilityLabel: String = "Sections"

    @Namespace private var glow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { segment(for: $0) }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func segment(for option: Option) -> some View {
        let selected = option == selection
        return Button {
            guard !selected else { return }
            HapticManager.shared.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) { selection = option }
        } label: {
            HStack(spacing: 6) {
                if let s = symbol(option) {
                    Image(systemName: s).font(.system(size: 13, weight: .bold))
                }
                Text(title(option))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? LuminousPalette.void : LuminousPalette.ink.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 42)
            .background {
                if selected {
                    Capsule()
                        .fill(LuminousPalette.signalGradientHorizontal)
                        .shadow(color: LuminousPalette.cyan.opacity(0.45), radius: 12)
                        .matchedGeometryEffect(id: "luminous-segment-glow", in: glow)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(option))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Glow slider

/// A slider whose track is lit with the colours it controls and whose thumb
/// glows. Drag anywhere on the track; VoiceOver adjusts in 5 % steps.
/// `onEditingChanged` brackets a drag like a system Slider does — debounced
/// writers rely on it.
struct LuminousGlowSlider: View {
    var title: String? = nil
    var symbol: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var colors: [Color] = [LuminousPalette.cyan, LuminousPalette.violet]
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var showsHeader: Bool = true
    var accessibilityName: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (value - range.lowerBound) / span))
    }

    private var hasHeader: Bool { showsHeader && (title != nil || symbol != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasHeader {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.first ?? LuminousPalette.cyan)
                    }
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LuminousPalette.ink.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    Text(format(value))
                        .font(LuminousType.value)
                        .foregroundStyle(LuminousPalette.ink.opacity(dragging ? 1 : 0.7))
                        .contentTransition(.numericText())
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let thumb: CGFloat = 26
                let x = CGFloat(fraction) * (width - thumb)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .frame(height: 10)
                    Capsule()
                        .fill(LinearGradient(colors: colors.isEmpty ? [LuminousPalette.cyan] : colors,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, x + thumb / 2), height: 10)
                        .shadow(color: (colors.last ?? .white).opacity(0.55), radius: dragging ? 12 : 7)
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: (colors.last ?? .white).opacity(0.8), radius: dragging ? 14 : 8)
                        .overlay(Circle().fill((colors.last ?? .white).opacity(0.25)).padding(7))
                        .scaleEffect(dragging && !reduceMotion ? 1.12 : 1)
                        .offset(x: x)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard isEnabled else { return }
                            if !dragging {
                                dragging = true
                                onEditingChanged(true)
                                HapticManager.shared.selection()
                            }
                            let f = max(0, min(1, Double((g.location.x - thumb / 2) / max(1, width - thumb))))
                            value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in
                            guard dragging else { return }
                            dragging = false
                            onEditingChanged(false)
                        }
                )
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: dragging)
            }
            .frame(height: 30)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .frame(minHeight: hasHeader ? 58 : 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName ?? title ?? "Level")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

// MARK: - Actions

/// The big button that sends light out — the Composer's Go Live. Idle it
/// glows with the signal; `live` turns it green and it breathes.
struct LuminousPrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var live: Bool = false
    var busy: Bool = false
    var compact: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var breathe = false

    var body: some View {
        let radius: CGFloat = compact ? 14 : 18
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(LuminousPalette.void)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 14 : 17, weight: .bold))
                }
                Text(title)
                    .font(.system(compact ? .subheadline : .headline, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(LuminousPalette.void)
            .padding(.horizontal, compact ? 16 : 20)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(minHeight: compact ? 44 : 54)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(live ? LuminousPalette.liveGradient : LuminousPalette.signalGradient))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: (live ? LuminousPalette.live : LuminousPalette.cyan).opacity(breathe && live ? 0.8 : 0.45),
                    radius: breathe && live ? 22 : 14)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
        .onAppear {
            guard !reduceMotion, live else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// The quiet partner of the primary button: glass, ink, optional accent.
struct LuminousSecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.ink
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(destructive ? LuminousPalette.danger : tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .luminousGlass(radius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle(scale: 0.96))
    }
}

/// A round power button that glows in the colour it switches.
struct LuminousPowerButton: View {
    let isOn: Bool
    var tint: Color = LuminousPalette.amber
    var size: CGFloat = 40
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(isOn ? LuminousPalette.void : LuminousPalette.ink.opacity(0.6))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isOn
                                  ? AnyShapeStyle(RadialGradient(colors: [Color.white, tint], center: .topLeading,
                                                                 startRadius: 0, endRadius: size))
                                  : AnyShapeStyle(Color.white.opacity(0.08)))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(isOn ? 0.4 : 0.14), lineWidth: 1))
                .shadow(color: isOn ? tint.opacity(0.7) : .clear, radius: 10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(LuminousPressStyle(scale: 0.88))
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Badges

/// A glowing disc behind an SF Symbol — the icon of a room, scene or setting.
struct LuminousIconBadge: View {
    let symbol: String
    var tint: Color = LuminousPalette.cyan
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

/// LIVE / PREVIEW / ON NOW — the Composer's state badge.
struct LuminousLiveBadge: View {
    enum Mode { case live, preview, paused, active }
    let state: Mode
    var text: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .shadow(color: dot.opacity(0.9), radius: state == .live ? 5 : 0)
                .scaleEffect(state == .live && pulse && !reduceMotion ? 1.35 : 1)
            Text(label)
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(isGreen ? LuminousPalette.live : LuminousPalette.ink.opacity(0.75))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(isGreen ? LuminousPalette.live.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        .onAppear {
            guard !reduceMotion, state == .live else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(label.capitalized)
    }

    private var isGreen: Bool { state == .live || state == .active }

    private var dot: Color {
        switch state {
        case .live, .active: return LuminousPalette.live
        case .preview: return LuminousPalette.cyan
        case .paused: return LuminousPalette.inkSecondary
        }
    }

    private var label: String {
        if let text { return text.uppercased() }
        switch state {
        case .live: return "LIVE"
        case .preview: return "PREVIEW"
        case .paused: return "PAUSED"
        case .active: return "ON NOW"
        }
    }
}

/// A small glass capsule with an icon and words, for facts on a stage.
struct LuminousFactBadge: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Capsule().fill(.ultraThinMaterial))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lists

/// A glass group of rows (settings, devices, people).
struct LuminousGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                LuminousEyebrow(text: title)
                    .padding(.horizontal, 6)
            }
            VStack(spacing: 0) { content() }
                .luminousGlass()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// One row: glowing icon, title, a sentence, an accessory.
struct LuminousRow<Accessory: View>: View {
    let symbol: String
    var tint: Color = LuminousPalette.cyan
    let title: String
    var subtitle: String? = nil
    var subtitleTint: Color = LuminousPalette.inkSecondary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            LuminousIconBadge(symbol: symbol, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(subtitleTint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

extension LuminousRow where Accessory == LuminousChevron {
    init(symbol: String, tint: Color = LuminousPalette.cyan, title: String, subtitle: String? = nil,
         subtitleTint: Color = LuminousPalette.inkSecondary) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.subtitleTint = subtitleTint
        self.accessory = { LuminousChevron() }
    }
}

struct LuminousChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LuminousPalette.inkTertiary)
            .accessibilityHidden(true)
    }
}

/// The hairline between rows of a group, inset past the icon.
struct LuminousRowDivider: View {
    var inset: CGFloat = 66
    var body: some View {
        Rectangle().fill(LuminousPalette.hairline).frame(height: 1).padding(.leading, inset)
    }
}

// MARK: - Text field

/// A glass text field: an optional caption above, an optional symbol that
/// lights when the field is in use, a clear button, a glow while focused,
/// and an optional character cap whose count appears in the last four.
struct LuminousTextField: View {
    var caption: String? = nil
    let placeholder: String
    @Binding var text: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.cyan
    var limit: Int? = nil
    var autofocus: Bool = false
    var capitalization: TextInputAutocapitalization = .words
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption {
                LuminousEyebrow(text: caption).padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(focused || !text.isEmpty ? tint : LuminousPalette.inkSecondary)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(LuminousPalette.inkTertiary))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                    .textInputAutocapitalization(capitalization)
                    .tint(tint)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(caption ?? placeholder)
                if !text.isEmpty {
                    Button {
                        text = ""
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, text.isEmpty ? 16 : 0)
            .frame(minHeight: 52)
            .luminousGlass(radius: 16, accent: tint, selected: focused)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)

            if let limit, text.count > limit - 4 {
                Text("\(max(0, limit - text.count)) characters remaining")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(text.count >= limit ? LuminousPalette.danger : LuminousPalette.inkSecondary)
                    .padding(.horizontal, 6)
            }
        }
        .onChange(of: text) { _, newValue in
            if let limit, newValue.count > limit {
                text = String(newValue.prefix(limit))
            }
        }
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - Feedback

/// A dismissible glass notice — the Composer's banner.
struct LuminousNotice: View {
    let text: String
    var symbol: String = "info.circle.fill"
    var tint: Color = LuminousPalette.cyan
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(LuminousPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, onDismiss == nil ? 14 : 0)
        .padding(.vertical, onDismiss == nil ? 12 : 0)
        .luminousGlass(radius: 16, raised: true)
    }
}

/// Nothing here yet: an icon in the spectrum, a sentence, an action.
struct LuminousEmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(LuminousPalette.spectrum)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.white.opacity(0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .accessibilityHidden(true)
            Text(title)
                .font(LuminousType.cardTitle)
                .foregroundStyle(LuminousPalette.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                LuminousPrimaryButton(title: actionTitle, compact: true, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .luminousGlass()
    }
}

// MARK: - Light → screen

/// Real lamp state as screen colour and as stage frames, so a room, a light
/// and a look are all drawn by the same painter.
enum LuminousLight {
    /// CIE xy of a white at `mirek` (Kim et al. Planckian approximation).
    static func xy(mirek: Int) -> (x: Double, y: Double) {
        let t = max(1667.0, min(25000.0, 1_000_000.0 / Double(max(1, mirek))))
        let t2 = t * t, t3 = t2 * t
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// The colour a light is showing (ignoring brightness). A non-nil mirek
    /// means the lamp is in white mode (the bridge nulls it in colour mode);
    /// a lamp that only dims reads as warm white.
    static func xy(of light: LightDisplayItem) -> (x: Double, y: Double) {
        if let mirek = light.colorTempMirek, mirek > 0 { return xy(mirek: mirek) }
        if let x = light.colorX, let y = light.colorY { return (x, y) }
        return xy(mirek: 370)
    }

    static func color(of light: LightDisplayItem) -> Color {
        let p = xy(of: light)
        return HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100)
    }

    /// 0…1 how bright the lamp is right now (0 when off; a lit lamp never
    /// reads as dark on screen).
    static func level(of light: LightDisplayItem) -> Double {
        light.isOn ? max(0.08, min(1, light.brightness / 100)) : 0
    }

    /// Stage frames for the Composer's painter, one per light, in order.
    /// An off lamp is neutral glass: the painter tints even a dark orb's rim
    /// with its frame colour, and a lamp that is off shows no colour.
    static func frames(for lights: [LightDisplayItem]) -> [Composer2Frame] {
        lights.enumerated().map { i, light in
            guard light.isOn else { return Composer2Frame(slot: i, x: 0.3127, y: 0.3290, brightness: 0) }
            let p = xy(of: light)
            return Composer2Frame(slot: i, x: p.x, y: p.y, brightness: level(of: light))
        }
    }

    /// The colours a group of lamps is showing, brightest first, for
    /// ambience and glows. Off lamps contribute nothing; near-identical
    /// colours count once.
    static func palette(of lights: [LightDisplayItem], max count: Int = 4) -> [Color] {
        var out: [Color] = []
        var seen: [(x: Double, y: Double)] = []
        for light in lights.sorted(by: { level(of: $0) > level(of: $1) }) where light.isOn {
            let p = xy(of: light)
            if seen.contains(where: { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.02 }) { continue }
            seen.append(p)
            out.append(HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100))
            if out.count >= count { break }
        }
        return out
    }
}
