// Composer2LayersView.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// The Layers tab: the look as a stack of behaviors, top over bottom, the way
// light blends. Each row plays that behavior on its own in a small live
// strip. Tap a row to open its editor; add from the behavior library;
// rename, duplicate, reorder, change how it blends, or switch it off.

import SwiftUI

struct Composer2LayersView: View {
    let document: Composer2Document
    @State private var showLibrary = false
    @State private var renameTarget: Composer2Layer?
    @State private var renameText = ""
    @State private var notice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layers: [Composer2Layer] { document.composition.layers }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Composer2SectionTitle(title: "Layers",
                                  subtitle: "Behaviors stack like light: the top one lands on the ones below.") {
                Composer2RoundButton(symbol: "plus", label: "Add a behavior", size: 40,
                                     tint: Composer2Theme.violet, filled: true) {
                    HapticManager.shared.medium()
                    showLibrary = true
                }
            }
            // Top of the stack first.
            ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                Composer2LayerRow(document: document, layer: layer, position: index, total: layers.count,
                                  onRename: { renameText = layer.name; renameTarget = layer },
                                  onRefused: { notice = $0 })
                    .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity),
                                            removal: .opacity))
            }
            if let notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Composer2Theme.coral)
            }
            Button {
                HapticManager.shared.medium()
                showLibrary = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("Add a behavior")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Composer2Theme.void)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Composer2Theme.violet, Composer2Theme.magenta],
                                             startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: Composer2Theme.violet.opacity(0.45), radius: 16, y: 6)
            }
            .buttonStyle(Composer2PressStyle())
            .accessibilityHint("Lightning, fireworks, chases, candle flame and more")
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: layers.map(\.id))
        .sheet(isPresented: $showLibrary) {
            Composer2BehaviorPicker { template in
                var layer = template.layer()
                layer.id = UUID()
                document.addLayer(layer)
                notice = nil
                Composer2PlaybackCenter.shared.noteEditBurst()
            }
        }
        .alert("Rename behavior", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let target = renameTarget, !trimmed.isEmpty { document.editLayer(id: target.id) { $0.name = trimmed } }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }
}

// MARK: - Row

struct Composer2LayerRow: View {
    let document: Composer2Document
    let layer: Composer2Layer
    /// 0 = bottom of the stack.
    let position: Int
    let total: Int
    let onRename: () -> Void
    let onRefused: (String) -> Void

    private var isSelected: Bool { layer.id == document.selectedLayerID }
    private var accent: Color { Composer2Theme.swatches(of: solo, max: 1).first ?? Composer2Theme.cyan }

    /// The layer on its own, for the row's live strip.
    private var solo: Composer2Composition {
        var one = layer
        one.enabled = true
        one.opacity = 1
        one.blend = .replace
        return Composer2Composition(id: layer.id, name: layer.name, createdAt: Date(timeIntervalSince1970: 0),
                                    master: document.composition.master, layers: [one])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Composer2MiniStage(composition: solo, lights: 6)
                    .frame(width: 84, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .opacity(layer.enabled ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 3) {
                    Text(layer.name)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(layer.enabled ? Composer2Theme.ink : Composer2Theme.muted)
                        .lineLimit(1)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Composer2Theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { layer.enabled }, set: { on in
                    HapticManager.shared.selection()
                    document.setLayer(id: layer.id, enabled: on)
                    Composer2PlaybackCenter.shared.noteEditBurst()
                }))
                .labelsHidden()
                .tint(accent)
                .accessibilityLabel("\(layer.name) on")
            }
            HStack(spacing: 8) {
                tag(blendName, symbol: "square.2.layers.3d")
                if let events = layer.events { tag(eventName(events), symbol: "bolt.fill") }
                if layer.audio.isActive { tag("Listens", symbol: "waveform") }
                Spacer(minLength: 0)
                Menu {
                    Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                    Button {
                        HapticManager.shared.medium()
                        document.duplicateLayer(id: layer.id)
                    } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Menu {
                        ForEach(Composer2BlendMode.allCases, id: \.self) { mode in
                            Button {
                                document.editLayer(id: layer.id) { $0.blend = mode }
                                Composer2PlaybackCenter.shared.noteEditBurst()
                            } label: {
                                if layer.blend == mode {
                                    Label(Composer2LayerRow.blendTitle(mode), systemImage: "checkmark")
                                } else {
                                    Text(Composer2LayerRow.blendTitle(mode))
                                }
                            }
                        }
                    } label: { Label("Blend", systemImage: "square.2.layers.3d") }
                    Button { move(up: true) } label: { Label("Move up", systemImage: "arrow.up") }
                        .disabled(position >= total - 1)
                    Button { move(up: false) } label: { Label("Move down", systemImage: "arrow.down") }
                        .disabled(position == 0)
                    Divider()
                    Button(role: .destructive) { remove() } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Composer2Theme.ink)
                        .frame(width: 44, height: 36)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .accessibilityLabel("More for \(layer.name)")
                Button {
                    HapticManager.shared.light()
                    document.select(layerID: layer.id)
                    document.activeEditor = .palette
                } label: {
                    Text("Edit")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Composer2Theme.void)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(Composer2PressStyle())
                .accessibilityLabel("Edit \(layer.name)")
            }
        }
        .padding(12)
        .composer2Glass(cornerRadius: 22, accent: accent, selected: isSelected, raised: true)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            HapticManager.shared.selection()
            document.select(layerID: layer.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layer.name), layer \(position + 1) of \(total), \(layer.enabled ? "on" : "off")")
    }

    private var summary: String {
        "\(Composer2Copy.summary(color: layer.color)) · \(Composer2Copy.summary(motion: layer.motion))"
    }

    private var blendName: String { Composer2LayerRow.blendTitle(layer.blend) }

    static func blendTitle(_ mode: Composer2BlendMode) -> String {
        switch mode {
        case .replace: return "Covers below"
        case .addLighten: return "Adds light"
        case .maxBrightness: return "Brighter wins"
        }
    }

    private func eventName(_ events: Composer2EventSpec) -> String {
        switch events.shape {
        case .flash: return "Flashes"
        case .lightning: return "Lightning"
        case .firework: return "Fireworks"
        case .twinkle: return "Twinkles"
        case .glow: return "Glows"
        }
    }

    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Composer2Theme.ink.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    private func move(up: Bool) {
        HapticManager.shared.selection()
        document.moveLayer(id: layer.id, up: !up)   // the list shows the top of the stack first
    }

    private func remove() {
        HapticManager.shared.medium()
        if !document.removeLayer(id: layer.id) { onRefused(Composer2Copy.keepOneBehavior) }
    }
}

// MARK: - Behavior picker

struct Composer2BehaviorPicker: View {
    let onPick: (Composer2BehaviorTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Composer2BehaviorTemplate.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundStyle(Composer2Theme.ink)
                                Text(group.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Composer2Theme.muted)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(Composer2BehaviorTemplate.templates(in: group)) { template in
                                    tile(template)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.vertical, 16)
            }
            .background(Composer2Theme.background.ignoresSafeArea())
            .navigationTitle("Add a behavior")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func tile(_ template: Composer2BehaviorTemplate) -> some View {
        let preview = Composer2Composition(id: UUID(uuidString: "0000000C-0009-0009-0009-000000000000")!,
                                           name: template.title, createdAt: Date(timeIntervalSince1970: 0),
                                           layers: [template.layer()])
        let accent = Composer2Theme.swatches(of: preview, max: 1).first ?? Composer2Theme.cyan
        return Button {
            HapticManager.shared.success()
            onPick(template)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Composer2MiniStage(composition: preview, lights: 6)
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 6) {
                    Image(systemName: template.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                    Text(template.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Composer2Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(Composer2Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .composer2Glass(cornerRadius: 18)
        }
        .buttonStyle(Composer2PressStyle(scale: 0.97))
        .accessibilityLabel("\(template.title). \(template.subtitle)")
        .accessibilityHint("Adds this behavior to the look")
    }
}
