// HueTypography.swift
// CastChroma — Stage 1 Typography Token System
// Extracted from Stitch designs. SF Pro system fonts throughout.

import SwiftUI

// MARK: - Font Tokens

enum HueFont {
    // MARK: Display
    /// 34pt Bold — "Good evening, Brian" greeting
    static let displayLarge   = Font.system(size: 34, weight: .bold, design: .default)
    /// 28pt Bold — Screen titles (Scenes, Devices, Settings)
    static let displayMedium  = Font.system(size: 28, weight: .bold, design: .default)
    /// 22pt Semibold — Section screen titles
    static let displaySmall   = Font.system(size: 22, weight: .semibold, design: .default)

    // MARK: Hero Numbers (Rounded — for brightness %, stats)
    /// 48pt Bold Rounded — "82%" brightness hero
    static let numberHero     = Font.system(size: 48, weight: .bold, design: .rounded)
    /// 28pt Bold Rounded — Sensor readings, count badges
    static let numberLarge    = Font.system(size: 28, weight: .bold, design: .rounded)
    /// 20pt Semibold Rounded — Medium stats, percentages
    static let numberMedium   = Font.system(size: 20, weight: .semibold, design: .rounded)

    // MARK: Content
    /// 17pt Semibold — Room names, scene names, nav titles
    static let headline       = Font.system(size: 17, weight: .semibold, design: .default)
    /// 15pt Regular — Card subtitles, list items, descriptions
    static let subheadline    = Font.system(size: 15, weight: .regular, design: .default)
    /// 15pt Regular — Body text
    static let body           = Font.system(size: 15, weight: .regular, design: .default)
    /// 15pt Medium — Emphasized body
    static let bodyMedium     = Font.system(size: 15, weight: .medium, design: .default)
    /// 13pt Regular — Secondary body, list item details
    static let callout        = Font.system(size: 13, weight: .regular, design: .default)
    /// 12pt Regular — Labels, secondary info, section header content
    static let caption        = Font.system(size: 12, weight: .regular, design: .default)
    /// 12pt Medium — Emphasized captions, scene chip labels
    static let captionMedium  = Font.system(size: 12, weight: .medium, design: .default)
    /// 10pt Medium — Tab bar labels, micro badges
    static let micro          = Font.system(size: 10, weight: .medium, design: .default)

    // MARK: Section Headers (all-caps, tracking)
    /// Uppercase tracking label for section headers ("INDIVIDUAL UNITS")
    static func sectionHeader() -> some View {
        EmptyView() // Use via ViewModifier below
    }

    // MARK: Stage (adjustment surfaces — text-style-relative so Dynamic Type scales)
    /// Mono bold uppercase tag — deck/section labels, sheet titles. Apply ~1.2 tracking at call site.
    static let stageTag     = Font.system(.caption2, design: .monospaced).weight(.bold)
    /// Mono value readouts (slider values, BPM, Hz, Kelvin).
    static let stageValue   = Font.system(.caption, design: .monospaced).weight(.medium)
    /// Control titles (slider / toggle / swatch-row labels).
    static let stageControl = Font.system(.footnote).weight(.medium)
    /// Card and effect names in tray headers.
    static let stageName    = Font.system(.callout).weight(.bold)
    /// Chip labels (pill pickers, capsule buttons).
    static let stageChip    = Font.system(.caption).weight(.semibold)
}

// MARK: - Typography ViewModifiers

struct HueSectionHeaderStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .default))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(
                colorScheme == .dark
                    ? HuePalette.Noir.textSecondary
                    : HuePalette.Estate.textSecondary
            )
    }
}

struct HueHeroNumberStyle: ViewModifier {
    var color: Color = HuePalette.amber

    func body(content: Content) -> some View {
        content
            .font(HueFont.numberHero)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

extension View {
    func hueSectionHeader() -> some View {
        modifier(HueSectionHeaderStyle())
    }

    func hueHeroNumber(color: Color = HuePalette.amber) -> some View {
        modifier(HueHeroNumberStyle(color: color))
    }
}

// MARK: - Text Style Convenience

extension Text {
    func displayLarge() -> Text {
        self.font(HueFont.displayLarge)
    }
    func displayMedium() -> Text {
        self.font(HueFont.displayMedium)
    }
    func headline() -> Text {
        self.font(HueFont.headline)
    }
    func caption() -> Text {
        self.font(HueFont.caption)
    }
}
