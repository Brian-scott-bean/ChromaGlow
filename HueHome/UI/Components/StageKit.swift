// StageKit.swift
// CastChroma — Round 4 stage design system components.
//
// The small reusable set the design-spec mockups are built from: stage
// surface cards, labeled sliders with mono value readouts, animated
// 8-segment pattern-signature strips, and status badges. Visual language:
// stage black surfaces, Hue amber accent, condensed uppercase tracked
// display labels, mono data labels.
//
// PatternStripView's animation is a pure function of (index, pattern, time)
// via StageStripMath — no accumulated state, unit-testable, and honors
// Reduce Motion with a static fallback.

import SwiftUI

// MARK: - Stage Palette

/// Stage tokens from the Round-3/4 design artifact. The app's amber
/// (`HuePalette.amber`) and live green (`HuePalette.Noir.success`) stay the
/// accent sources of truth; these fill the neutral surface roles.
enum StagePalette {
    /// #0B0B0F — the stage itself (screen background).
    static let stage = Color(hex: "#0B0B0F")
    /// #16161D — card / tray surface.
    static let surface = Color(hex: "#16161D")
    /// #1E1E27 — raised elements (tracks, wells) on a surface.
    static let raised = Color(hex: "#1E1E27")
    /// #F2F0EA — primary ink.
    static let ink = Color(hex: "#F2F0EA")
    /// #8F8C99 — secondary/muted text.
    static let muted = Color(hex: "#8F8C99")
    /// Hairline stroke on surfaces.
    static let line = Color.white.opacity(0.10)
}

// MARK: - Stage Card

/// The artifact's "ed-block": a stage surface card with an uppercase
/// mono-tracked section label, optional subtitle, and arbitrary content.
struct StageCard<Content: View>: View {
    let icon: String?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    init(icon: String? = nil,
         title: String,
         subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HuePalette.amber.opacity(0.85))
                    }
                    Text(title.uppercased())
                        .font(HueFont.stageTag)
                        .foregroundStyle(.white.opacity(0.38))
                        .tracking(1.2)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StagePalette.line, lineWidth: 1)
        )
    }
}

// MARK: - Stage Slider

/// Labeled slider row: title left, mono value right, amber tint.
/// Generalizes the Composer's original `compositionSlider`.
struct StageSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var onEditingChanged: ((Bool) -> Void)? = nil

    init(title: String,
         value: Binding<Double>,
         range: ClosedRange<Double>,
         format: @escaping (Double) -> String = { "\(Int($0.rounded()))" },
         onEditingChanged: ((Bool) -> Void)? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Text(format(value))
                    .font(HueFont.stageValue)
                    .foregroundStyle(.white.opacity(0.40))
            }
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
            }
            .tint(HuePalette.amber)
        }
    }
}

// MARK: - Stage Badge

/// Small status pill: LIVE / ENT AREA / coverage counts.
struct StageBadge: View {
    enum Style {
        case live
        case amber
        case muted
    }

    let text: String
    var style: Style = .muted

    init(text: String, style: Style = .muted) {
        self.text = text
        self.style = style
    }

    private var foreground: Color {
        switch style {
        case .live:  return HuePalette.Noir.success
        case .amber: return HuePalette.amber
        case .muted: return .white.opacity(0.55)
        }
    }

    private var background: Color {
        switch style {
        case .live:  return HuePalette.Noir.success.opacity(0.13)
        case .amber: return HuePalette.amber.opacity(0.14)
        case .muted: return .white.opacity(0.10)
        }
    }

    var body: some View {
        Text(text)
            .font(HueFont.stageTag)
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }
}

// MARK: - Stage Toggle Row

/// Labeled toggle row: title left, amber toggle right. 44pt minimum height.
struct StageToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(HueFont.stageControl)
                .foregroundStyle(.white.opacity(0.60))
        }
        .tint(HuePalette.amber)
        .frame(minHeight: 44)
    }
}

// MARK: - Stage Swatch Math

/// Color matching for swatch selection. `Color` equality is unreliable across
/// construction paths (hex vs xy round-trips), so compare resolved RGB with a
/// tolerance instead.
enum StageSwatchMath {
    static func matches(_ a: Color, _ b: Color, tolerance: Double = 0.01) -> Bool {
        let ra = a.resolve(in: EnvironmentValues())
        let rb = b.resolve(in: EnvironmentValues())
        return abs(Double(ra.red - rb.red)) <= tolerance
            && abs(Double(ra.green - rb.green)) <= tolerance
            && abs(Double(ra.blue - rb.blue)) <= tolerance
    }
}

// MARK: - Stage Color Swatch Row

/// Label + tappable preset color circles. Circles render at 28pt but sit in a
/// 44pt hit area. Selection ring follows `selected` via tolerance matching.
struct StageColorSwatchRow: View {
    let title: String
    let swatches: [Color]
    let selected: Color?
    let onSelect: (Color) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(HueFont.stageControl)
                .foregroundStyle(.white.opacity(0.60))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                        let isSelected = selected.map { StageSwatchMath.matches($0, color) } ?? false
                        Button {
                            HapticManager.shared.selection()
                            onSelect(color)
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().strokeBorder(.white, lineWidth: isSelected ? 2 : 0)
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Stage More Button

/// The "+N more ▾" progressive-disclosure affordance shared by the mixer tray
/// and the composer layer tabs.
struct StageMoreButton: View {
    let count: Int
    var isExpanded: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.light()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(isExpanded ? "SHOW LESS" : "+\(count) MORE")
                    .font(HueFont.stageTag)
                    .tracking(1.0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(StagePalette.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stage Sheet Scaffold

/// Unified chrome for every adjustment sheet: stage background, mono tracked
/// title, medium/large detents, and background interaction at medium so the
/// lights stay visible while adjusting.
struct StageSheetScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    content()
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(StagePalette.stage)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title.uppercased())
                        .font(HueFont.stageTag)
                        .tracking(1.2)
                        .foregroundStyle(StagePalette.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 13, weight: .semibold))
                        .tint(HuePalette.amber)
                }
            }
            .toolbarBackground(StagePalette.stage, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Pattern Strip Math

/// Pure brightness signatures for the 8-segment pattern strip. Everything is
/// a function of (segment index, pattern, wall time) so the view never
/// accumulates phase and the math is unit-testable.
enum StageStripMath {
    static let segmentCount = 8

    /// Idle floor so trailing cells stay faintly visible.
    static let floorOpacity = 0.14
    /// Static fallback level (Reduce Motion / not animated).
    static let staticOpacity = 0.6

    /// Deterministic per-index phase offsets for twinkle (from the artifact's
    /// stagger table) — shared so tests can reason about them.
    private static let twinklePhases: [Double] = [0.33, 0.76, 0.05, 0.52, 0.90, 0.19, 0.67, 0.43]
    /// Fixed shuffle for scatter — cascade sweep through a scrambled order.
    private static let scatterOrder: [Int] = [3, 7, 1, 5, 0, 6, 2, 4]

    private static func wrap(_ x: Double) -> Double { x - x.rounded(.down) }

    /// Brightness (0…1) of one strip segment for a pattern at a moment in time.
    static func opacity(index: Int, pattern: MotionConfig.Pattern, time: TimeInterval) -> Double {
        let i = max(0, min(segmentCount - 1, index))
        let n = Double(segmentCount)
        let f = Double(i) / n

        switch pattern {
        case .static:
            return staticOpacity

        case .cascade:
            // Phase-offset sweep with a soft linear tail.
            let p = wrap(time / 1.8 - f)
            return max(floorOpacity, 1.0 - min(1.0, p * 2.0))

        case .wave:
            let s = 0.5 + 0.5 * sin(2 * .pi * (time / 2.0 - f))
            return floorOpacity + (1 - floorOpacity) * s

        case .spiral:
            // Angular sweep, twisted: two heads chasing around the strip.
            let s = 0.5 + 0.5 * sin(2 * .pi * (time / 2.4 - f * 2.0))
            return floorOpacity + (1 - floorOpacity) * s * s

        case .chase:
            // Hot traveling cell with a sharp exponential tail.
            let p = wrap(time / 1.6 - f)
            return p < 0.09 ? 1.0 : max(floorOpacity, exp(-p * 4.5))

        case .comet:
            // Traveling head with a long luminous tail.
            let p = wrap(time / 2.0 - f)
            return max(floorOpacity, exp(-p * 2.0))

        case .pulseCenter:
            // Symmetric ripple expanding from the strip's center.
            let d = abs(Double(i) - (n - 1) / 2) / ((n - 1) / 2)   // 0 center … 1 edge
            let p = wrap(time / 2.0 - d * 0.45)
            return max(floorOpacity, 1.0 - min(1.0, p * 2.2))

        case .scatter:
            // Cascade sweep through a fixed scrambled segment order.
            let fShuffled = Double(scatterOrder[i]) / n
            let p = wrap(time / 1.8 - fShuffled)
            return max(floorOpacity, 1.0 - min(1.0, p * 2.0))

        case .bounce:
            // Ping-pong head across the strip.
            let ph = wrap(time / 2.2)
            let pos = ph < 0.5 ? ph * 2 * (n - 1) : (1 - ph) * 2 * (n - 1)
            return max(floorOpacity, 1.0 - min(1.0, abs(Double(i) - pos) / 2.0))

        case .twinkle:
            // Per-cell stochastic-looking pulse from deterministic offsets.
            let s = 0.5 + 0.5 * sin(2 * .pi * (time / 2.1 + twinklePhases[i]))
            return 0.12 + 0.88 * s * s
        }
    }
}

// MARK: - Pattern Strip View

/// The artifact's animated 8-segment "pattern signature" strip. Opacity per
/// cell is a pure function of time — zero @State, one TimelineView.
struct PatternStripView: View {
    let pattern: MotionConfig.Pattern
    var accent: Color = HuePalette.amber
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive

    init(pattern: MotionConfig.Pattern, accent: Color = HuePalette.amber, animated: Bool = true) {
        self.pattern = pattern
        self.accent = accent
        self.animated = animated
    }

    // Also paused when the host tab is off-screen — these strips would otherwise
    // redraw at 12fps per card behind the visible tab.
    private var isLive: Bool { animated && !reduceMotion && isTabActive }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isLive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<StageStripMath.segmentCount, id: \.self) { i in
                    Capsule()
                        .fill(accent)
                        .frame(height: 8)
                        .opacity(isLive
                                 ? StageStripMath.opacity(index: i, pattern: pattern, time: t)
                                 : StageStripMath.staticOpacity)
                }
            }
        }
        .accessibilityHidden(true)   // decorative signature; state is announced elsewhere
    }
}

// MARK: - Previews

#Preview("StageKit") {
    ScrollView {
        VStack(spacing: 16) {
            StageCard(icon: "wind", title: "Motion", subtitle: "How color travels across lights over time.") {
                PatternStripView(pattern: .chase)
                StageSlider(title: "Speed", value: .constant(40), range: 0...100)
            }
            StageCard(icon: "bolt.fill", title: "React") {
                HStack {
                    StageBadge(text: "LIVE", style: .live)
                    StageBadge(text: "ENT AREA", style: .amber)
                    StageBadge(text: "4 OF 6 LIGHTS", style: .muted)
                }
            }
            ForEach(MotionConfig.Pattern.allCases, id: \.self) { pattern in
                HStack {
                    Text(pattern.rawValue)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StagePalette.muted)
                        .frame(width: 90, alignment: .leading)
                    PatternStripView(pattern: pattern)
                }
            }
        }
        .padding(20)
    }
    .background(StagePalette.stage)
    .preferredColorScheme(.dark)
}
