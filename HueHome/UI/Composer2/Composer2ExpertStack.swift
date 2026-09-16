// Composer2ExpertStack.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// "Build Your Own Light Behavior": the modular stack. Each row is one
// behavior layer with its primitives summarised; add, remove, enable,
// duplicate and reorder without a node editor.

import SwiftUI

struct Composer2ExpertStack: View {
    let document: Composer2Document
    @State private var notice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Composer2Copy.buildYourOwnTitle)
                    .font(HueFont.displaySmall)
                    .foregroundStyle(Composer2Theme.ink)
                Text(Composer2Copy.buildYourOwnSubtitle)
                    .font(HueFont.subheadline)
                    .foregroundStyle(Composer2Theme.muted)
            }
            ForEach(Array(document.composition.layers.enumerated()), id: \.element.id) { index, layer in
                Composer2BehaviorRow(document: document, layer: layer, index: index,
                                     total: document.composition.layers.count,
                                     onRefused: { notice = $0 })
            }
            addMenu
            if let notice {
                Text(notice)
                    .font(HueFont.captionMedium)
                    .foregroundStyle(Composer2Theme.coral)
            }
        }
        .padding(HueSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composer2Glass(accent: Composer2Theme.violet, selected: true)
    }

    private var addMenu: some View {
        Menu {
            Button("Blank behavior") { add(.blank()) }
            Divider()
            ForEach(Composer2PresetLibrary.all) { preset in
                ForEach(preset.layers) { layer in
                    Button("\(preset.name) · \(layer.name)") { add(layer) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(Composer2Copy.addBehavior)
                    .font(HueFont.bodyMedium)
            }
            .foregroundStyle(Composer2Theme.background)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Composer2Theme.violet, Composer2Theme.magenta], startPoint: .leading, endPoint: .trailing)))
            .shadow(color: Composer2Theme.violet.opacity(0.4), radius: 12)
        }
        .accessibilityLabel(Composer2Copy.addBehavior)
    }

    private func add(_ layer: Composer2Layer) {
        HapticManager.shared.medium()
        withAnimation(reduceMotion ? nil : HueAnimation.fast) {
            document.addLayer(layer)
        }
        notice = nil
    }
}

// MARK: - Row

struct Composer2BehaviorRow: View {
    let document: Composer2Document
    let layer: Composer2Layer
    let index: Int
    let total: Int
    let onRefused: (String) -> Void

    @State private var renaming = false
    @State private var draftName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { layer.id == document.selectedLayerID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(HueFont.stageTag)
                    .foregroundStyle(Composer2Theme.background)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(layer.enabled ? Composer2Theme.cyan : Composer2Theme.muted))
                Text(layer.name)
                    .font(HueFont.stageName)
                    .foregroundStyle(layer.enabled ? Composer2Theme.ink : Composer2Theme.muted)
                    .lineLimit(1)
                if !layer.enabled {
                    StageBadge(text: "OFF", style: .muted)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { layer.enabled }, set: { on in
                    HapticManager.shared.selection()
                    document.setLayer(id: layer.id, enabled: on)
                }))
                .labelsHidden()
                .tint(Composer2Theme.cyan)
                .scaleEffect(0.8)
                .frame(width: 44, height: 30)
                .accessibilityLabel("\(layer.name) enabled")
                Menu {
                    Button { draftName = layer.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { HapticManager.shared.medium(); document.duplicateLayer(id: layer.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { move(up: true) } label: { Label("Move up", systemImage: "arrow.up") }.disabled(index == 0)
                    Button { move(up: false) } label: { Label("Move down", systemImage: "arrow.down") }.disabled(index >= total - 1)
                    Divider()
                    Button(role: .destructive) { remove() } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Composer2Theme.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Composer2Theme.glassRaised))
                }
                .accessibilityLabel("More actions for \(layer.name)")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                chip("Color", Composer2Copy.summary(color: layer.color), .palette)
                chip("Motion", Composer2Copy.summary(motion: layer.motion), .motion)
                chip("Rhythm", Composer2Copy.summary(rhythm: layer.rhythm), .rhythm)
                chip("Space", Composer2Copy.summary(mask: layer.mask, total: document.roomContext.layout.count, direction: layer.motion), .space)
                chip("Events", Composer2Copy.summary(events: layer.events), .events)
                chip("Variation", Composer2Copy.summary(variation: layer.variation), .variation)
            }

            HStack(spacing: 8) {
                Text(blendName)
                    .font(HueFont.stageStatus)
                    .foregroundStyle(Composer2Theme.muted)
                Spacer(minLength: 0)
                Button { move(up: true) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 36) }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(layer.name) up")
                Button { move(up: false) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 36) }
                    .disabled(index >= total - 1)
                    .accessibilityLabel("Move \(layer.name) down")
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Composer2Theme.ink)
            .buttonStyle(.plain)
        }
        .padding(12)
        .composer2Glass(accent: Composer2Theme.cyan, selected: isSelected, raised: true)
        .opacity(layer.enabled ? 1 : 0.6)
        .onTapGesture { document.select(layerID: layer.id) }
        .alert("Rename behavior", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { document.editLayer(id: layer.id) { $0.name = trimmed } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Behavior \(index + 1), \(layer.name), \(layer.enabled ? "on" : "off")")
    }

    private var blendName: String {
        switch layer.blend {
        case .replace: return "Blend: replace"
        case .addLighten: return "Blend: add light"
        case .maxBrightness: return "Blend: brighter wins"
        }
    }

    private func chip(_ title: String, _ value: String, _ editor: Composer2Editor) -> some View {
        Button {
            HapticManager.shared.light()
            document.select(layerID: layer.id)
            document.activeEditor = editor
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(HueFont.stageTag)
                    .foregroundStyle(editor.dimension.map { Composer2Theme.accent(for: $0) } ?? Composer2Theme.coral)
                Text(value)
                    .font(HueFont.captionMedium)
                    .foregroundStyle(Composer2Theme.ink.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Composer2Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Composer2Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint("Edits \(title.lowercased()) for \(layer.name)")
    }

    private func move(up: Bool) {
        HapticManager.shared.selection()
        withAnimation(reduceMotion ? nil : HueAnimation.fast) {
            document.moveLayer(id: layer.id, up: up)
        }
    }

    private func remove() {
        HapticManager.shared.medium()
        let removed = withAnimation(reduceMotion ? nil : HueAnimation.fast) {
            document.removeLayer(id: layer.id)
        }
        if !removed { onRefused(Composer2Copy.keepOneBehavior) }
    }
}
