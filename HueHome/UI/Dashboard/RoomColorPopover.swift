// RoomColorPopover.swift
// ChromaGlow — long-press a room card, paint the room
//
// The Dashboard's fastest path from "I want this room amber" to amber: hold a
// room (or zone) card and this sheet appears — a color wheel, a brightness
// slider, the harmony rules, and the user's saved colors. Apply paints the
// room: one grouped write for a single color, a per-light spread when a
// harmony rule is on (adjacent bulbs wear different anchors — that is the
// point of harmony).
//
// Everything here is reuse: ColorWheelView (per-light control), HarmonyEngine
// (composer), SavedColorStrip (My Colors), the Luminous glow slider, and the
// send pacing that RoomColorWashPlanner + applyColorWash inherit from the
// effects engine. The orbs show what the room will look like.

import SwiftUI

struct RoomColorPopover: View {

    let room: RoomDisplayItem
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var hue: Double = 0.09          // warm amber start
    @State private var saturation: Double = 0.75
    @State private var brightness: Double = 80
    @State private var rule: HarmonyRule = .none
    @State private var isApplying = false

    /// Rules that spread well across a room. Four-colour rules are excluded
    /// for the same reason the composer excludes them: past three anchors a
    /// room reads as noise, not a palette.
    private var rules: [HarmonyRule] {
        HarmonyRule.allCases.filter { $0.anchorCount <= 3 }
    }

    /// What the wash will look like: the harmony anchors at the current root.
    private var washColors: [Color] {
        HarmonyEngine.palette(rule: rule, rootHue: hue, saturation: saturation, brightness: 1.0,
                              count: max(3, rule.anchorCount))
            .map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    LuminousScreenTitle(title: room.name,
                                        eyebrow: "Colour wash",
                                        eyebrowSymbol: "paintbrush.fill",
                                        eyebrowTint: washColors.first ?? LuminousPalette.cyan,
                                        subtitle: "One colour for the whole room — or a harmony that spreads several across it.")

                    // ── The wheel ────────────────────────────
                    ColorWheelView(hue: $hue, saturation: $saturation) { _, _ in
                        HapticManager.shared.selection()
                    }
                    .frame(width: 230, height: 230)
                    .frame(maxWidth: .infinity)

                    // ── What the room will look like ─────────
                    LuminousPaletteOrbs(colors: washColors, count: max(3, washColors.count), height: 54)
                        .opacity(0.35 + 0.65 * brightness / 100)
                        .padding(.vertical, 4)
                        .luminousGlass(radius: 18)
                        .animation(HueAnimation.fast, value: rule)

                    // ── Brightness ───────────────────────────
                    LuminousGlowSlider(title: "Brightness",
                                       symbol: "sun.max.fill",
                                       value: $brightness,
                                       range: 1...100,
                                       colors: [washColors.first?.opacity(0.5) ?? LuminousPalette.cyan, washColors.first ?? LuminousPalette.violet],
                                       format: { "\(Int($0.rounded()))%" })

                    // ── Harmony rules ────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        LuminousEyebrow(text: "Harmony")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(rules, id: \.self) { candidate in
                                    LuminousChip(title: candidate == .none ? "Single" : candidate.rawValue,
                                                 symbol: candidate.icon,
                                                 selected: rule == candidate,
                                                 accent: washColors.first ?? LuminousPalette.cyan) {
                                        rule = candidate
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollClipDisabled()
                    }

                    // ── Saved colours ────────────────────────
                    if !SavedColorStore.shared.colors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LuminousEyebrow(text: "My Colors")
                            SavedColorStrip { saved in
                                guard let x = saved.x, let y = saved.y else { return }
                                let hsb = HueColorUtils.hsb(fromX: x, y: y, brightness: 100)
                                hue = hsb.h
                                saturation = hsb.s
                                brightness = saved.brightness
                                HapticManager.shared.selection()
                            }
                            .padding(.horizontal, -16)
                        }
                    }

                    LuminousPrimaryButton(title: rule == .none ? "Apply to \(room.name)" : "Spread across \(room.name)",
                                          symbol: "paintbrush.fill",
                                          busy: isApplying) {
                        apply()
                    }
                    .disabled(isApplying)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background { LuminousAmbience(colors: washColors) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .luminousSheet()
    }

    // MARK: - Apply

    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        HapticManager.shared.medium()
        let snapshot = (rule: rule, hue: hue, sat: saturation, bri: brightness)
        Task {
            await orchestrator.applyColorWash(
                to: room,
                rule: snapshot.rule,
                rootHue: snapshot.hue,
                saturation: snapshot.sat,
                brightness: snapshot.bri
            )
            isApplying = false
        }
    }
}
