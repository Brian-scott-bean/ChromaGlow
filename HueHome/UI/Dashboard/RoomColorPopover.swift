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
// (composer), SavedColorStrip (My Colors), StageSlider (everywhere), and the
// send pacing that RoomColorWashPlanner + applyColorWash inherit from the
// effects engine.

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

    /// Rules that spread well across a room. Four-color rules are excluded for
    /// the same reason the composer excludes them: past three anchors a room
    /// reads as noise, not a palette.
    private var rules: [HarmonyRule] {
        HarmonyRule.allCases.filter { $0.anchorCount <= 3 }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HueSpacing.lg) {

                    // ── The wheel ────────────────────────────
                    ColorWheelView(hue: $hue, saturation: $saturation) { _, _ in
                        HapticManager.shared.selection()
                    }
                    .frame(width: 220, height: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.top, HueSpacing.sm)

                    // ── Harmony preview swatches ─────────────
                    harmonyPreview

                    // ── Brightness ───────────────────────────
                    StageSlider(
                        title: "Brightness",
                        value: $brightness,
                        range: 1...100,
                        format: { "\(Int($0.rounded()))%" }
                    )

                    // ── Harmony rules ────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HARMONY")
                            .font(HueFont.stageTag)
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.45))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(rules, id: \.self) { candidate in
                                    ruleChip(candidate)
                                }
                            }
                        }
                    }

                    // ── Saved colors ─────────────────────────
                    if !SavedColorStore.shared.colors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MY COLORS")
                                .font(HueFont.stageTag)
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.45))
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

                    applyButton
                }
                .padding(.horizontal, HueSpacing.lg)
                .padding(.bottom, HueSpacing.lg)
            }
            .background(StagePalette.stage)
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(HuePalette.amber)
                }
            }
            .toolbarBackground(StagePalette.stage, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    /// What the wash will look like: the harmony anchors at the current root.
    private var harmonyPreview: some View {
        let colors = HarmonyEngine.palette(
            rule: rule, rootHue: hue, saturation: saturation, brightness: 1.0,
            count: max(3, rule.anchorCount)
        )
        return HStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, paletteColor in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hue: paletteColor.hue,
                                saturation: paletteColor.saturation,
                                brightness: paletteColor.brightness))
                    .frame(height: 22)
            }
        }
        .animation(HueAnimation.fast, value: rule)
    }

    private func ruleChip(_ candidate: HarmonyRule) -> some View {
        let selected = rule == candidate
        return Button {
            rule = candidate
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: candidate.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(candidate == .none ? "Single" : candidate.rawValue)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? HuePalette.amber : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var applyButton: some View {
        Button {
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
        } label: {
            HStack {
                if isApplying {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "paintbrush.fill")
                }
                Text(rule == .none ? "Apply to \(room.name)" : "Spread across \(room.name)")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: HueRadius.lg).fill(HuePalette.amber))
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }
}
