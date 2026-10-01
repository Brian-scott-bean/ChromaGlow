// LuminousMoreParts.swift
// ChromaGlow — Luminous design language: the parts the setup screens share
// (More, Settings, Automations, Devices, Bridges, People, Sync).
//
// Candidates for LuminousKit; kept here so the kit itself has one owner.
//   • LuminousPage            — a pushed screen: ambience, title block, scroll.
//   • LuminousSheetScaffold   — a sheet: the same, with Done and detents.
//   • LuminousTitledCard      — a glass card with an icon + title line.
//   • LuminousRowButtonStyle  — a row inside a glass group answers the finger.
//   • LuminousToggleRow       — glowing icon, words, a signal-tinted switch.
//   • LuminousTextBadge       — a tiny capsule word ("LIVE", "FIRMWARE").
//   • LuminousTextField       — a glass input with a caption above it.
//   • LuminousAppIdentityRow  — the spectrum ring, the name, the version.
//   • BridgeConnectionSummary — the one honest sentence about the bridges.

import SwiftUI

// MARK: - Page

/// A pushed screen in the Luminous language: the ambience behind it, the
/// Composer's title block, then content on the standard margins. The system
/// back button stays (edge swipe keeps working) over a transparent bar; the
/// bar's own centre title is blank because the content carries the name,
/// but the title still names the screen to the back button of the next one.
struct LuminousPage<Content: View>: View {
    let title: String
    var eyebrow: String? = nil
    var eyebrowSymbol: String? = nil
    var tint: Color = LuminousPalette.cyan
    var subtitle: String? = nil
    /// Colours the background glows in; the tint alone when empty.
    var ambience: [Color] = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                LuminousScreenTitle(title: title, eyebrow: eyebrow, eyebrowSymbol: eyebrowSymbol,
                                    eyebrowTint: tint, subtitle: subtitle)
                content()
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { LuminousAmbience(colors: ambience.isEmpty ? [tint] : ambience, intensity: 0.7) }
        .luminousPageChrome(title: title)
    }
}

extension View {
    /// The bar of a pushed Luminous screen: transparent, dark, an empty
    /// centre (the content names the screen) — while `title` still reaches
    /// the next screen's back button.
    func luminousPageChrome(title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            .preferredColorScheme(.dark)
    }
}

// MARK: - Sheet

/// A sheet in the Luminous language: its own navigation stack, the title
/// block, the ambience, a Done in the signal colour, medium/large detents.
struct LuminousSheetScaffold<Content: View>: View {
    let title: String
    var eyebrow: String? = nil
    var eyebrowSymbol: String? = nil
    var tint: Color = LuminousPalette.cyan
    var subtitle: String? = nil
    var ambience: [Color] = []
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LuminousScreenTitle(title: title, eyebrow: eyebrow, eyebrowSymbol: eyebrowSymbol,
                                        eyebrowTint: tint, subtitle: subtitle)
                    content()
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { LuminousAmbience(colors: ambience.isEmpty ? [tint] : ambience, intensity: 0.65) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationBackground(LuminousPalette.void)
        .preferredColorScheme(.dark)
    }
}

/// A glass card headed by a glowing icon and a title — the Luminous
/// successor of the old stage card, for sheets with a few distinct parts.
struct LuminousTitledCard<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = LuminousPalette.cyan
    var glow: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LuminousIconBadge(symbol: symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(LuminousType.cardTitle)
                        .foregroundStyle(LuminousPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .luminousPanel(radius: LuminousPalette.panelRadius, glow: glow, glowStrength: 0.4)
    }
}

// MARK: - Rows

/// A row inside a `LuminousGroup`: pressing lifts it a shade.
struct LuminousRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.07 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Glowing icon, a title, a sentence, and a switch tinted with the signal.
struct LuminousToggleRow: View {
    let symbol: String
    var tint: Color = LuminousPalette.cyan
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                LuminousIconBadge(symbol: symbol, tint: tint, size: 36, lit: isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(LuminousPalette.cyan)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
    }
}

/// A tiny capsule word on a row or card.
struct LuminousTextBadge: View {
    let text: String
    var tint: Color = LuminousPalette.live

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// A glass text input with a caption above it.
struct LuminousTextField: View {
    let caption: String
    let placeholder: String
    @Binding var text: String
    var capitalization: TextInputAutocapitalization = .words

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: caption).padding(.horizontal, 6)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(LuminousPalette.inkTertiary))
                .font(.body.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
                .textInputAutocapitalization(capitalization)
                .tint(LuminousPalette.cyan)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .luminousGlass(radius: 16)
                .accessibilityLabel(caption)
        }
    }
}

// MARK: - Identity

/// The app's name and version beside a glowing spectrum ring — the icon's
/// neon "G" in miniature.
struct LuminousAppIdentityRow: View {
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(LuminousPalette.void)
                Circle()
                    .strokeBorder(LuminousPalette.spectrum, lineWidth: 3)
                    .padding(6)
                    .blur(radius: 3)
                    .opacity(0.8)
                Circle()
                    .strokeBorder(LuminousPalette.spectrum, lineWidth: 2)
                    .padding(6)
            }
            .frame(width: 44, height: 44)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("ChromaGlow")
                    .font(LuminousType.cardTitle)
                    .foregroundStyle(LuminousPalette.ink)
                Text("Version \(BuildMetadata.current.marketingVersion) · Build \(BuildMetadata.current.buildNumber)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(LuminousPalette.inkSecondary)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(LuminousPalette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connection

/// The one honest sentence about the bridges' live (SSE) connections.
struct BridgeConnectionSummary {
    let connected: Int
    let total: Int

    init(_ statuses: [String: BridgeConnectionStatus]) {
        total = statuses.count
        connected = statuses.values.filter { if case .connected = $0 { return true }; return false }.count
    }

    var tint: Color {
        if total == 0 { return LuminousPalette.inkSecondary }
        if connected == total { return LuminousPalette.live }
        if connected == 0 { return LuminousPalette.danger }
        return LuminousPalette.amber
    }

    var label: String {
        if total == 0 { return "No bridges configured" }
        if connected == total { return "All \(total) bridge\(total == 1 ? "" : "s") connected" }
        return "\(connected) of \(total) connected"
    }

    var isHealthy: Bool { total > 0 && connected == total }
}

extension BridgeConnectionStatus {
    /// Colour and words for one bridge's live connection.
    var luminousTint: Color {
        switch self {
        case .connected: return LuminousPalette.live
        case .connecting: return LuminousPalette.amber
        case .error: return LuminousPalette.danger
        case .disabled: return LuminousPalette.inkSecondary
        }
    }
}
