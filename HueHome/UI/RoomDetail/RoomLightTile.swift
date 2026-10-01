// RoomLightTile.swift
// ChromaGlow — Room (Luminous): one lamp, drawn as light.
//
// A glass tile lit by the lamp it stands for: an orb in the lamp's real
// colour and brightness (dark glass when off), its name, its level, a power
// button that glows in its colour. Tap opens the lamp; in select mode a tap
// toggles it instead and a check replaces the power button.
//
// Paint mode, the drop target and the context menu are attached at the call
// site (RoomDetailView) — they belong to the room, not the tile.
// Power flips locally at once and resyncs to bridge truth.

import SwiftUI

struct RoomLightTile: View {
    let light: LightDisplayItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// Family Sharing: false hides the power button (status-only tile).
    var showsPowerToggle: Bool = true
    let onToggle: (Bool) -> Void
    var onToggleSelect: () -> Void = {}

    @State private var localIsOn: Bool

    init(light: LightDisplayItem, isSelecting: Bool = false, isSelected: Bool = false,
         showsPowerToggle: Bool = true, onToggle: @escaping (Bool) -> Void,
         onToggleSelect: @escaping () -> Void = {}) {
        self.light = light
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.showsPowerToggle = showsPowerToggle
        self.onToggle = onToggle
        self.onToggleSelect = onToggleSelect
        _localIsOn = State(initialValue: light.isOn)
    }

    private var color: Color { LuminousLight.color(of: light) }
    private var level: Double { localIsOn ? max(0.08, min(1, light.brightness / 100)) : 0 }

    private var statusText: String {
        localIsOn ? "\(BrightnessDisplay.percent(light.brightness))%" : "Off"
    }

    private var capabilityText: String {
        if light.supportsColor { return "Color" }
        if light.supportsColorTemp { return "White" }
        return "Dims"
    }

    var body: some View {
        Group {
            if isSelecting {
                Button(action: onToggleSelect) { tile }
                    .buttonStyle(LuminousPressStyle(scale: 0.97))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            } else {
                // Long-press is the context menu's gesture (attached at the
                // call site) — no competing recognizer here.
                NavigationLink(value: light) { tile }
                    .buttonStyle(LuminousPressStyle(scale: 0.97))
            }
        }
        .overlay(alignment: .topTrailing) { trailingControl.padding(4) }
        .opacity(isSelecting ? (isSelected ? 1 : 0.6) : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: localIsOn)
        .animation(.spring(response: 0.3), value: isSelecting)
        .animation(.spring(response: 0.25), value: isSelected)
        .onChange(of: light.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { localIsOn = confirmed }
            }
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousLampOrb(color: color, level: level, size: 30)
                .frame(width: 54, height: 54)
                .padding(.leading, -6)
            VStack(alignment: .leading, spacing: 2) {
                Text(light.name)
                    .font(LuminousType.cardTitleSmall)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(statusText)
                        .foregroundStyle(localIsOn ? color : LuminousPalette.inkSecondary)
                        .contentTransition(.numericText())
                    Text("·").foregroundStyle(LuminousPalette.inkTertiary)
                    Text(capabilityText).foregroundStyle(LuminousPalette.inkSecondary)
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .luminousPanel(radius: 20, glow: localIsOn ? color : nil, glowStrength: localIsOn ? 0.35 + 0.65 * level : 0)
        .overlay {
            if isSelecting && isSelected {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LuminousPalette.cyan, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(light.name), \(statusText)")
        .accessibilityHint(isSelecting ? "Double tap to select" : "Opens the light")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
                .frame(width: 44, height: 44)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityHidden(true)
        } else if showsPowerToggle {
            LuminousPowerButton(isOn: localIsOn, tint: color, size: 34,
                                label: "Turn \(light.name) \(localIsOn ? "off" : "on")") {
                HapticManager.shared.light()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { localIsOn.toggle() }
                onToggle(localIsOn)
            }
            .accessibilityHint(localIsOn ? "Tap to turn off" : "Tap to turn on")
        }
    }
}
