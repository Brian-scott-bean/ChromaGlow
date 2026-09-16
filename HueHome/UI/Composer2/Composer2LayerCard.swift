// Composer2LayerCard.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// One creative dimension of the selected behavior: icon, name, a human
// value line, a live mini-preview, an on/off switch and a disclosure into
// its editor. Six of these make the Customize mode.

import SwiftUI

struct Composer2LayerCard<Preview: View>: View {
    let dimension: Composer2Dimension
    let valueText: String
    let isOn: Bool
    let showsToggle: Bool
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    @ViewBuilder let preview: () -> Preview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Composer2Theme.accent(for: dimension) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(isOn ? 0.18 : 0.08))
                        .frame(width: 30, height: 30)
                    Image(systemName: dimension.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? accent : Composer2Theme.muted)
                }
                Text(dimension.title)
                    .font(HueFont.stageName)
                    .foregroundStyle(Composer2Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if showsToggle {
                    Toggle("", isOn: Binding(get: { isOn }, set: { newValue in
                        HapticManager.shared.selection()
                        withAnimation(reduceMotion ? nil : HueAnimation.fast) { onToggle(newValue) }
                    }))
                    .labelsHidden()
                    .tint(accent)
                    .scaleEffect(0.72)
                    .frame(width: 40, height: 28)
                    .accessibilityLabel("\(dimension.title) enabled")
                } else if !isOn {
                    StageBadge(text: "OFF", style: .muted)
                }
            }

            preview()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
                .opacity(isOn ? 1 : 0.45)

            HStack(alignment: .firstTextBaseline) {
                Text(valueText)
                    .font(HueFont.captionMedium)
                    .foregroundStyle(isOn ? Composer2Theme.ink.opacity(0.85) : Composer2Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Composer2Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composer2Glass(accent: accent, selected: isOn)
        .opacity(isOn ? 1 : 0.7)
        .contentShape(RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous))
        .onTapGesture {
            HapticManager.shared.light()
            onOpen()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(dimension.title), \(valueText), \(isOn ? "on" : "off")")
        .accessibilityHint("Double tap to edit")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Build Your Own card

struct Composer2BuildYourOwnCard: View {
    let layerCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.medium()
            onOpen()
        } label: {
            HStack(spacing: HueSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Composer2Theme.violet, Composer2Theme.magenta],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                        .shadow(color: Composer2Theme.violet.opacity(0.5), radius: 12)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Composer2Theme.background)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(Composer2Copy.buildYourOwnTitle)
                        .font(HueFont.headline)
                        .foregroundStyle(Composer2Theme.ink)
                    Text(Composer2Copy.buildYourOwnSubtitle)
                        .font(HueFont.caption)
                        .foregroundStyle(Composer2Theme.muted)
                    Text(layerCount == 1 ? "1 behavior" : "\(layerCount) behaviors")
                        .font(HueFont.stageStatus)
                        .foregroundStyle(Composer2Theme.violet)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Composer2Theme.muted)
            }
            .padding(HueSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .composer2Glass(accent: Composer2Theme.violet, selected: true, raised: true)
            .contentShape(RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Composer2Copy.buildYourOwnTitle). \(Composer2Copy.buildYourOwnSubtitle)")
        .accessibilityHint("Opens Expert mode")
    }
}
