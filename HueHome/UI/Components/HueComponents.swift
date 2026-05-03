// HueComponents.swift
// CastChroma — Stage 1 Component Library
// Reusable primitives used across every screen.
// All components consume tokens from HueTokens.swift + HueTypography.swift.

import SwiftUI

// MARK: - GlassCard

/// The foundational card surface — frosted dark in Noir, white with shadow in Estate
struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    var padding: CGFloat = HueSpacing.cardPad
    var radius: CGFloat = HueRadius.lg
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(HuePalette.Noir.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(HuePalette.Noir.surfaceBorder, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(HuePalette.Estate.surface)
                        .shadow(
                            color: HueShadows.card.color,
                            radius: HueShadows.card.radius,
                            x: HueShadows.card.x,
                            y: HueShadows.card.y
                        )
                }
            }
    }
}

// MARK: - StatPill

/// Compact status pill e.g. "4 on" — amber in dark, amber-tinted in light
struct StatPill: View {
    @Environment(\.colorScheme) var colorScheme
    let label: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: HueSpacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .font(HueFont.captionMedium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(colorScheme == .dark
                      ? HuePalette.amber.opacity(0.18)
                      : HuePalette.amberLight.opacity(0.15))
        )
        .foregroundStyle(
            colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight
        )
    }
}

// MARK: - HuePrimaryButton

/// Full-width primary CTA — amber background, black text (Stitch spec)
struct HuePrimaryButton: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HueSpacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.black)
                        .scaleEffect(0.85)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(HuePalette.Noir.ctaText)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: HueRadius.md, style: .continuous)
                    .fill(colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - HueSecondaryButton

/// Outlined secondary button
struct HueSecondaryButton: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HueSpacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: HueRadius.md, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SectionHeader

/// Uppercase section label with optional trailing count badge
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .hueSectionHeader()

            Spacer()

            if let count {
                Text("\(count)")
                    .font(HueFont.micro)
                    .foregroundStyle(.secondary)
            }

            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HuePalette.amber)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HueSpacing.lg)
        .padding(.top, HueSpacing.md)
        .padding(.bottom, HueSpacing.xs)
    }
}

// MARK: - HueDivider

/// Hairline divider using token color
struct HueDivider: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark
                  ? HuePalette.Noir.separator
                  : HuePalette.Estate.separator)
            .frame(height: 0.5)
    }
}

// MARK: - AmberToggle

/// iOS-style toggle with amber on-state tint
struct AmberToggle: View {
    @Binding var isOn: Bool
    var action: ((Bool) -> Void)? = nil

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(HuePalette.amber)
            .onChange(of: isOn) { _, newValue in
                action?(newValue)
            }
    }
}

// MARK: - HueBrightnessBar

/// Thin amber gradient progress bar used in room cards
struct HueBrightnessBar: View {
    var value: Double  // 0–100
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: height)

                Capsule()
                    .fill(LinearGradient.hueAmberFill)
                    .frame(width: geo.size.width * CGFloat(value / 100), height: height)
            }
        }
        .frame(height: height)
    }
}

// MARK: - AmberRadialGlow

/// Soft ambient glow — appears behind illuminated room icons
struct AmberRadialGlow: View {
    @Environment(\.colorScheme) var colorScheme
    var radius: CGFloat = 80

    var body: some View {
        RadialGradient(
            colors: [
                HuePalette.amber.opacity(colorScheme == .dark ? 0.22 : 0.14),
                .clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
        .allowsHitTesting(false)
    }
}

// MARK: - SceneChip

/// Horizontal scene selector chip
struct SceneChip: View {
    @Environment(\.colorScheme) var colorScheme
    let name: String
    var icon: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HueSpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(name)
                    .font(HueFont.captionMedium)
                    .lineLimit(1)
            }
            .padding(.horizontal, HueSpacing.md)
            .padding(.vertical, HueSpacing.sm)
            .background {
                RoundedRectangle(cornerRadius: HueRadius.md, style: .continuous)
                    .fill(isActive
                          ? (colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight)
                          : (colorScheme == .dark ? HuePalette.Noir.surface : HuePalette.Estate.surface))
                    .overlay {
                        if !isActive {
                            RoundedRectangle(cornerRadius: HueRadius.md, style: .continuous)
                                .strokeBorder(
                                    colorScheme == .dark
                                        ? HuePalette.Noir.surfaceBorder
                                        : HuePalette.Estate.surfaceBorder,
                                    lineWidth: 1
                                )
                        }
                    }
            }
            .foregroundStyle(isActive
                             ? Color.black
                             : (colorScheme == .dark ? HuePalette.Noir.textPrimary : HuePalette.Estate.textPrimary))
        }
        .buttonStyle(.plain)
        .animation(HueAnimation.toggle, value: isActive)
    }
}

// MARK: - SSE Connection Dot

/// Pulsing status dot for nav bar — green/yellow/red
enum ConnectionState {
    case connected, reconnecting, disconnected

    var color: Color {
        switch self {
        case .connected:     return Color(hex: "#30D158")
        case .reconnecting:  return Color(hex: "#FF9500")
        case .disconnected:  return Color(hex: "#FF3B30")
        }
    }
}

struct SSEConnectionDot: View {
    var state: ConnectionState = .connected
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color.opacity(0.25))
                .scaleEffect(pulsing ? 1.8 : 1.0)
                .animation(
                    state == .connected
                        ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )

            Circle()
                .fill(state.color)
        }
        .frame(width: 8, height: 8)
        .onAppear { pulsing = true }
    }
}
