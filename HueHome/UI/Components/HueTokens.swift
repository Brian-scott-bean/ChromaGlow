// HueTokens.swift
// CastChroma — Stage 1 Design Token System
// Single source of truth for colors, spacing, radii, shadows.
// Extracted from Stitch: Luminous Noir (dark) + Luminous Estate (light).

import SwiftUI

// MARK: - Color Tokens

extension Color {
    static let hue = HuePalette.self
}

enum HuePalette {

    // MARK: Amber (Primary Accent — both themes)
    /// Bright amber — on-state, active elements, CTAs (dark theme)
    static let amber         = Color(hex: "#FFC107")
    /// Deeper amber — gradient endpoint, pressed states (dark theme)
    static let amberDeep     = Color(hex: "#FF9500")
    /// Lighter warm amber — on-state (light theme)
    static let amberLight    = Color(hex: "#F5A623")
    /// Deeper amber for light theme gradients
    static let amberLightDeep = Color(hex: "#E8920D")
    /// Ambient glow — translucent amber behind on-state icons
    static let amberGlow     = Color(hex: "#FFC107").opacity(0.18)
    static let amberGlowLight = Color(hex: "#F5A623").opacity(0.15)

    // MARK: Dark Theme — Luminous Noir
    enum Noir {
        static let background        = Color(hex: "#141414")
        static let surface           = Color(hex: "#242424")
        static let surfaceElevated   = Color(hex: "#2E2E2E")
        static let surfaceBorder     = Color.white.opacity(0.08)
        static let tabBar            = Color(hex: "#1C1C1C")

        static let textPrimary       = Color.white
        static let textSecondary     = Color.white.opacity(0.55)
        static let textTertiary      = Color.white.opacity(0.30)

        static let toggleOn          = Color(hex: "#FFC107")
        static let toggleOff         = Color(hex: "#3A3A3A")
        static let sliderTrack       = Color.white.opacity(0.12)

        static let tabActive         = Color(hex: "#FFC107")
        static let tabInactive       = Color.white.opacity(0.35)

        static let ctaBackground     = Color(hex: "#FFC107")
        static let ctaText           = Color.black

        static let destructive       = Color(hex: "#FF3B30")
        static let success           = Color(hex: "#30D158")
        static let separator         = Color.white.opacity(0.08)
    }

    // MARK: Light Theme — Luminous Estate
    enum Estate {
        static let background        = Color(hex: "#F2F2F7")
        static let surface           = Color.white
        static let surfaceElevated   = Color.white
        static let surfaceBorder     = Color.black.opacity(0.06)
        static let tabBar            = Color.white

        static let textPrimary       = Color(hex: "#1C1C1E")
        static let textSecondary     = Color.black.opacity(0.50)
        static let textTertiary      = Color.black.opacity(0.28)

        static let toggleOn          = Color(hex: "#F5A623")
        static let toggleOff         = Color(hex: "#D1D1D6")
        static let sliderTrack       = Color.black.opacity(0.08)

        static let tabActive         = Color(hex: "#F5A623")
        static let tabInactive       = Color.black.opacity(0.30)

        static let ctaBackground     = Color(hex: "#F5A623")
        static let ctaText           = Color.black

        static let destructive       = Color(hex: "#FF3B30")
        static let success           = Color(hex: "#34C759")
        static let separator         = Color.black.opacity(0.08)
    }
}

// MARK: - Adaptive Palette (resolves per color scheme)

struct HueAdaptiveColor {
    let dark: Color
    let light: Color

    func resolve(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? dark : light
    }
}

extension HuePalette {
    enum Adaptive {
        static let background      = HueAdaptiveColor(dark: Noir.background,      light: Estate.background)
        static let surface         = HueAdaptiveColor(dark: Noir.surface,         light: Estate.surface)
        static let surfaceElevated = HueAdaptiveColor(dark: Noir.surfaceElevated, light: Estate.surfaceElevated)
        static let surfaceBorder   = HueAdaptiveColor(dark: Noir.surfaceBorder,   light: Estate.surfaceBorder)
        static let textPrimary     = HueAdaptiveColor(dark: Noir.textPrimary,     light: Estate.textPrimary)
        static let textSecondary   = HueAdaptiveColor(dark: Noir.textSecondary,   light: Estate.textSecondary)
        static let textTertiary    = HueAdaptiveColor(dark: Noir.textTertiary,    light: Estate.textTertiary)
        static let primary         = HueAdaptiveColor(dark: HuePalette.amber,     light: HuePalette.amberLight)
        static let primaryDeep     = HueAdaptiveColor(dark: HuePalette.amberDeep, light: HuePalette.amberLightDeep)
        static let glow            = HueAdaptiveColor(dark: HuePalette.amberGlow, light: HuePalette.amberGlowLight)
        static let tabBar          = HueAdaptiveColor(dark: Noir.tabBar,          light: Estate.tabBar)
        static let tabActive       = HueAdaptiveColor(dark: Noir.tabActive,       light: Estate.tabActive)
        static let tabInactive     = HueAdaptiveColor(dark: Noir.tabInactive,     light: Estate.tabInactive)
        static let ctaBackground   = HueAdaptiveColor(dark: Noir.ctaBackground,   light: Estate.ctaBackground)
        static let separator       = HueAdaptiveColor(dark: Noir.separator,       light: Estate.separator)
        static let sliderTrack     = HueAdaptiveColor(dark: Noir.sliderTrack,     light: Estate.sliderTrack)
        static let destructive     = HueAdaptiveColor(dark: Noir.destructive,     light: Estate.destructive)
    }
}

// MARK: - Gradient Tokens

extension LinearGradient {
    /// Primary amber fill gradient (left → right) for sliders and bars
    static var hueAmberFill: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "#FFC107"), Color(hex: "#FF9500")],
            startPoint: .leading, endPoint: .trailing
        )
    }
    /// Vertical amber gradient for large hero elements
    static var hueAmberVertical: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "#FFC107"), Color(hex: "#FF7A00")],
            startPoint: .top, endPoint: .bottom
        )
    }
    /// Subtle room card on-state background glow
    static func hueRoomGlow(colorScheme: ColorScheme) -> RadialGradient {
        RadialGradient(
            colors: [Color(hex: "#FFC107").opacity(colorScheme == .dark ? 0.20 : 0.12), .clear],
            center: .topLeading,
            startRadius: 0,
            endRadius: 80
        )
    }
}

// MARK: - Spacing Tokens

enum HueSpacing {
    static let xs:      CGFloat = 4
    static let sm:      CGFloat = 8
    static let md:      CGFloat = 12
    static let lg:      CGFloat = 16
    static let xl:      CGFloat = 20
    static let xxl:     CGFloat = 24
    static let section: CGFloat = 32
    static let cardPad: CGFloat = 16   // standard card internal padding
    static let screenH: CGFloat = 20   // horizontal screen margin
    static let screenV: CGFloat = 16   // vertical screen margin
}

// MARK: - Corner Radius Tokens

enum HueRadius {
    static let sm:   CGFloat = 8
    static let md:   CGFloat = 12
    static let lg:   CGFloat = 16   // cards
    static let xl:   CGFloat = 20   // sheets, modals
    static let pill: CGFloat = 999  // toggles, pill buttons
}

// MARK: - Shadow Tokens (light mode only — dark uses glow)

struct HueShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum HueShadows {
    static let card     = HueShadow(color: .black.opacity(0.08), radius: 8,  x: 0, y: 2)
    static let elevated = HueShadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 4)
    static let modal    = HueShadow(color: .black.opacity(0.16), radius: 32, x: 0, y: 8)
    static let amber    = HueShadow(color: Color(hex: "#FFC107").opacity(0.40), radius: 16, x: 0, y: 4)
}

// MARK: - Animation Tokens

enum HueAnimation {
    static let fast:    Animation = .spring(response: 0.25, dampingFraction: 0.75)
    static let normal:  Animation = .spring(response: 0.35, dampingFraction: 0.80)
    static let slow:    Animation = .spring(response: 0.50, dampingFraction: 0.85)
    static let toggle:  Animation = .spring(response: 0.30, dampingFraction: 0.70)
    static let card:    Animation = .spring(response: 0.40, dampingFraction: 0.78)
    static let linear:  Animation = .linear(duration: 0.15)

    // ── Reduce Motion Support ─────────────────────────────────
    // Returns nil when user has Reduce Motion enabled (nil = instant, no animation).
    // Usage: withAnimation(HueAnimation.adaptive(.fast, reduceMotion: reduceMotion)) { ... }
    static func adaptive(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

// MARK: - Font Tokens
//
// See HueTypography.swift for the full HueFont token system.
// During page overhauls, migrate from .system(size: N) to
// Dynamic Type–compatible fonts (.subheadline, .caption, etc.)
// to support accessibility text scaling.

// MARK: - Accessibility Helpers
//
// Convenience functions for building VoiceOver labels and traits.
// Keeps accessibility logic consistent across all views.

enum HueAccessibility {
    /// Standard effect card label: "{name} effect"
    static func cardLabel(name: String) -> String {
        "\(name) effect"
    }

    /// Standard effect card hint based on running state
    static func cardHint(isRunning: Bool, roomName: String?) -> String {
        if isRunning {
            return "Double tap to stop"
        } else if let room = roomName {
            return "Double tap to apply to \(room)"
        } else {
            return "Select a room first"
        }
    }

    /// Room/zone label: "{name}, {lightCount} lights"
    static func roomLabel(name: String, lightCount: Int, isZone: Bool) -> String {
        let type = isZone ? "zone" : "room"
        return "\(name) \(type), \(lightCount) \(lightCount == 1 ? "light" : "lights")"
    }

    /// Slider value announcement: "{label}: {value}"
    static func sliderValue(label: String, value: Int) -> String {
        "\(label): \(value)"
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
