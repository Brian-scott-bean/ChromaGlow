// Composer2Controls.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2 redesign.
//
// The small set of controls the luminous Composer is built from: a glowing
// slider whose track is painted with the look's own colours, chips, round
// glass buttons, a springy press style and section headings. Every control
// is VoiceOver-adjustable and at least 44 pt to touch.

import SwiftUI

// MARK: - Press style

/// A soft spring on press — the whole instrument answers the finger.
struct Composer2PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - Section heading

struct Composer2SectionTitle<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Composer2Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Composer2Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension Composer2SectionTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

// MARK: - Glow slider

/// A slider whose track is lit with the look's own colours and whose thumb
/// glows. Drag anywhere on the track; VoiceOver adjusts in 5 % steps.
struct Composer2GlowSlider: View {
    let title: String
    var symbol: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var colors: [Color] = [Composer2Theme.cyan, Composer2Theme.violet]
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return Composer2Math.clamp01((value - range.lowerBound) / span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.first ?? Composer2Theme.cyan)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Composer2Theme.ink.opacity(0.9))
                Spacer(minLength: 0)
                Text(format(value))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Composer2Theme.ink.opacity(dragging ? 1 : 0.7))
                    .contentTransition(.numericText())
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
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
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
                // Sideways drags and taps only — an up/down swipe over the
                // track scrolls the page (build-60 H-2).
                .modifier(LuminousSliderInput(
                    onBegan: {
                        guard !dragging else { return }
                        dragging = true
                        onEditingChanged(true)
                        HapticManager.shared.selection()
                    },
                    onChanged: { x in
                        let f = Composer2Math.clamp01(Double((x - thumb / 2) / max(1, width - thumb)))
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    },
                    onEnded: {
                        guard dragging else { return }
                        dragging = false
                        onEditingChanged(false)
                    }))
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: dragging)
            }
            .frame(height: 30)
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
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

// MARK: - Chips and round buttons

struct Composer2Chip: View {
    let title: String
    var symbol: String? = nil
    var selected: Bool = false
    var accent: Color = Composer2Theme.cyan
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
            .foregroundStyle(selected ? Composer2Theme.void : Composer2Theme.ink.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.07)))
            )
            .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.9) : Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: selected ? accent.opacity(0.5) : .clear, radius: 10)
            .contentShape(Capsule())
        }
        .buttonStyle(Composer2PressStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct Composer2RoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 44
    var tint: Color = Composer2Theme.ink
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(filled ? Composer2Theme.void : tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(filled ? 0 : 0.14), lineWidth: 1))
                .shadow(color: filled ? tint.opacity(0.5) : .black.opacity(0.3), radius: filled ? 12 : 8)
                .contentShape(Circle())
        }
        .buttonStyle(Composer2PressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// A gradient built from a look's colours, used for washes and card art.
struct Composer2PaletteWash: View {
    let colors: [Color]
    var angle: Angle = .degrees(35)

    var body: some View {
        LinearGradient(colors: colors.isEmpty ? [Composer2Theme.navy] : colors,
                       startPoint: UnitPoint(x: 0.5 - cos(angle.radians) / 2, y: 0.5 - sin(angle.radians) / 2),
                       endPoint: UnitPoint(x: 0.5 + cos(angle.radians) / 2, y: 0.5 + sin(angle.radians) / 2))
    }
}
