// Composer2TuneView.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// The Tune tab: the few dials that change a look the most, in words anyone
// understands. Brightness, speed and energy for every look; frequency and
// strength when a look has moments (lightning, fireworks, sparkles); how far
// away the storm is and whether it passes, when a look has lightning; and
// its colours, one tap from the full palette editor. Everything writes into
// the same composition the Layers tab edits.

import SwiftUI

struct Composer2TuneView: View {
    let document: Composer2Document

    private var composition: Composer2Composition { document.composition }
    private var colors: [Color] { Composer2Theme.swatches(of: composition, max: 4) }

    private var lightningLayers: [Composer2Layer] {
        composition.layers.filter { $0.events?.shape == .lightning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Composer2SectionTitle(title: "Tune", subtitle: "Shape the look without touching the details.")
            feel
            if composition.hasEvents { moments }
            if !lightningLayers.isEmpty { storm }
            colours
            takes
        }
    }

    // MARK: Feel

    private var feel: some View {
        panel(title: "Feel", symbol: "slider.horizontal.3") {
            Composer2GlowSlider(title: "Brightness", symbol: "sun.max.fill", value: masterBinding(\.intensity),
                                colors: colors, onEditingChanged: burst)
            Composer2GlowSlider(title: "Speed", symbol: "hare.fill", value: speedBinding, colors: colors,
                                format: { Composer2QuickMapping.speedLabel(slider: $0) }, onEditingChanged: burst)
            Composer2GlowSlider(title: "Energy", symbol: "sparkles", value: energyBinding, colors: colors,
                                format: { Composer2QuickMapping.energyWord($0) }, onEditingChanged: burst)
        }
    }

    // MARK: Moments

    private var moments: some View {
        panel(title: "Moments", symbol: "bolt.fill",
              subtitle: "How often the lightning, sparkles or fireworks happen — and how hard they land.") {
            Composer2GlowSlider(title: "Frequency", symbol: "metronome.fill", value: rateBinding,
                                colors: [Composer2Theme.violet, Composer2Theme.cyan],
                                format: { Composer2QuickMapping.rateWord(slider: $0) }, onEditingChanged: burst)
            Composer2GlowSlider(title: "Strength", symbol: "bolt.horizontal.fill", value: masterBinding(\.eventStrength),
                                colors: [Composer2Theme.violet, .white], onEditingChanged: burst)
        }
    }

    // MARK: Storm

    private var storm: some View {
        panel(title: "Storm", symbol: "cloud.bolt.rain.fill",
              subtitle: "Real lightning: a leader, strokes and afterglow. Near is white and sudden; far is soft and rolling.") {
            Composer2GlowSlider(title: "Distance", symbol: "location.north.line.fill", value: distanceBinding,
                                colors: [.white, Composer2Theme.violet, Composer2Theme.navy],
                                format: { Composer2QuickMapping.distanceWord($0) }, onEditingChanged: burst)
            HStack(spacing: 8) {
                Text("Strikes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Composer2Theme.ink)
                Spacer(minLength: 0)
                Composer2Chip(title: "Random", symbol: "dice.fill", selected: !isRegular, accent: Composer2Theme.violet) {
                    setRegular(false)
                }
                Composer2Chip(title: "Regular", symbol: "metronome.fill", selected: isRegular, accent: Composer2Theme.violet) {
                    setRegular(true)
                }
            }
            .accessibilityElement(children: .contain)
            if isRegular {
                Composer2GlowSlider(title: "Every", symbol: "timer", value: intervalBinding,
                                    colors: [Composer2Theme.violet, Composer2Theme.cyan],
                                    format: { composer2Seconds(Composer2QuickMapping.interval(fromSlider: $0)) },
                                    onEditingChanged: burst)
            }
            Toggle(isOn: passingBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The storm passes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Composer2Theme.ink)
                    Text("Rolls in, breaks overhead and moves on, every four minutes.")
                        .font(.caption)
                        .foregroundStyle(Composer2Theme.muted)
                }
            }
            .tint(Composer2Theme.violet)
            .frame(minHeight: 44)
        }
    }

    // MARK: Colours

    private var colours: some View {
        panel(title: "Colors", symbol: "paintpalette.fill") {
            if composition.layers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(composition.layers) { layer in
                            Composer2Chip(title: layer.name, selected: layer.id == document.selectedLayerID,
                                          accent: Composer2Theme.magenta) {
                                document.select(layerID: layer.id)
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }
            HStack(spacing: 12) {
                ForEach(Array(document.selectedLayer.color.sanitizedStops.enumerated()), id: \.offset) { _, stop in
                    let c = Composer2Theme.solidColor(x: stop.x, y: stop.y)
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.7), c], center: .topLeading, startRadius: 0, endRadius: 30))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                        .shadow(color: c.opacity(0.7), radius: 9)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                Button {
                    HapticManager.shared.light()
                    document.activeEditor = .palette
                } label: {
                    Label("Edit", systemImage: "eyedropper.halffull")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Composer2Theme.void)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Capsule().fill(Composer2Theme.magenta))
                        .shadow(color: Composer2Theme.magenta.opacity(0.5), radius: 10)
                }
                .buttonStyle(Composer2PressStyle())
                .accessibilityLabel("Edit the colors of \(document.selectedLayer.name)")
            }
        }
    }

    // MARK: Another take

    private var takes: some View {
        Button {
            HapticManager.shared.medium()
            Composer2TuneView.reshuffle(document)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dice.fill")
                    .font(.system(size: 17, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Another take")
                        .font(.subheadline.weight(.bold))
                    Text("Same look, a fresh roll of every random choice.")
                        .font(.caption)
                        .foregroundStyle(Composer2Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Composer2Theme.ink)
            .padding(14)
            .composer2Glass(cornerRadius: 20)
        }
        .buttonStyle(Composer2PressStyle())
        .accessibilityHint("Reshuffles which lights sparkle and when things happen")
    }

    /// A fresh seed for every layer — the same look, a new sequence.
    static func reshuffle(_ document: Composer2Document, at date: Date = Date()) {
        let base = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        document.edit { composition in
            composition.master.seed = Composer2Hash.mix(base, 0xD1CE)
            for i in composition.layers.indices {
                composition.layers[i].variation.seed = Composer2Hash.mix(base, UInt64(i + 1))
                composition.layers[i].events?.seed = nil
            }
        }
        Composer2PlaybackCenter.shared.noteEditBurst()
    }

    // MARK: Plumbing

    private func panel<Content: View>(title: String, symbol: String, subtitle: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(colors.first ?? Composer2Theme.cyan)
                Text(title.uppercased())
                    .font(.caption.weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Composer2Theme.muted)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Composer2Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composer2Glass(cornerRadius: 22)
    }

    private func burst(_ editing: Bool) {
        if !editing { Composer2PlaybackCenter.shared.noteEditBurst() }
    }

    private func masterBinding(_ keyPath: WritableKeyPath<Composer2MasterControls, Double>) -> Binding<Double> {
        Binding(
            get: { document.composition.master[keyPath: keyPath] },
            set: { value in document.edit { $0.master[keyPath: keyPath] = Composer2Math.clamp01(value) } }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { Composer2QuickMapping.slider(fromSpeed: document.composition.master.speed) },
            set: { value in document.edit { $0.master.speed = Composer2QuickMapping.speed(fromSlider: value) } }
        )
    }

    private var energyBinding: Binding<Double> {
        Binding(
            get: { document.composition.master.energy },
            set: { value in document.edit { Composer2QuickMapping.apply(energy: value, to: &$0) } }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Composer2QuickMapping.slider(fromSpeed: document.composition.master.eventRate) },
            set: { value in document.edit { $0.master.eventRate = Composer2QuickMapping.speed(fromSlider: value) } }
        )
    }

    private var distanceBinding: Binding<Double> {
        Binding(
            get: { lightningLayers.first?.events?.distance ?? 0.35 },
            set: { value in
                document.edit { composition in
                    for i in composition.layers.indices where composition.layers[i].events?.shape == .lightning {
                        composition.layers[i].events?.distance = Composer2Math.clamp01(value)
                    }
                }
            }
        )
    }

    private var isRegular: Bool { lightningLayers.first?.events?.timing == .fixed }

    /// Random strikes, or one on a steady beat (periodic lightning). Switching
    /// keeps the same average pace.
    private func setRegular(_ regular: Bool) {
        document.edit { composition in
            for i in composition.layers.indices where composition.layers[i].events?.shape == .lightning {
                guard var e = composition.layers[i].events else { continue }
                if regular, e.timing != .fixed {
                    e.interval = (e.minDelay + e.maxDelay) / 2
                    e.timing = .fixed
                    e.probability = 1   // periodic means every time
                    e.activityPeriod = 0
                } else if !regular, e.timing != .random {
                    e.minDelay = max(0.5, e.interval * 0.5)
                    e.maxDelay = e.interval * 1.5
                    e.timing = .random
                }
                composition.layers[i].events = e
            }
        }
        Composer2PlaybackCenter.shared.noteEditBurst()
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { Composer2QuickMapping.slider(fromInterval: lightningLayers.first?.events?.interval ?? 8) },
            set: { value in
                let seconds = Composer2QuickMapping.interval(fromSlider: value)
                document.edit { composition in
                    for i in composition.layers.indices where composition.layers[i].events?.shape == .lightning {
                        composition.layers[i].events?.interval = seconds
                    }
                }
            }
        )
    }

    private var passingBinding: Binding<Bool> {
        Binding(
            get: { lightningLayers.contains { ($0.events?.activityPeriod ?? 0) > 0 } },
            set: { on in
                HapticManager.shared.selection()
                document.edit { composition in
                    for i in composition.layers.indices where composition.layers[i].events?.shape == .lightning {
                        composition.layers[i].events?.activityPeriod = on ? 240 : 0
                        composition.layers[i].events?.activityDepth = on ? 0.85 : 0
                    }
                }
            }
        )
    }
}

// MARK: - Pure mapping

enum Composer2QuickMapping {
    /// Speed slider 0…1 ↔ master speed 0.25…4 (log scale, 0.5 = ×1).
    static func slider(fromSpeed speed: Double) -> Double {
        let s = Composer2Math.clamp(speed, 0.25, 4)
        return Composer2Math.clamp01(0.5 + log2(s) / 4)
    }

    static func speed(fromSlider value: Double) -> Double {
        pow(2, (Composer2Math.clamp01(value) - 0.5) * 4)
    }

    static func speedLabel(slider value: Double) -> String {
        let s = speed(fromSlider: value)
        return String(format: "×%.2g", s)
    }

    static func rateWord(slider value: Double) -> String {
        let r = speed(fromSlider: value)
        switch r {
        case ..<0.45: return "Rare"
        case ..<0.85: return "Less often"
        case ..<1.2: return "As authored"
        case ..<2.2: return "More often"
        default: return "Relentless"
        }
    }

    /// Strike interval slider 0…1 ↔ 2…60 s (log scale).
    static func interval(fromSlider value: Double) -> Double {
        exp(log(2) + Composer2Math.clamp01(value) * (log(60) - log(2)))
    }

    static func slider(fromInterval seconds: Double) -> Double {
        let s = Composer2Math.clamp(seconds, 2, 60)
        return (log(s) - log(2)) / (log(60) - log(2))
    }

    static func distanceWord(_ d: Double) -> String {
        switch Composer2Math.clamp01(d) {
        case ..<0.2: return "Overhead"
        case ..<0.45: return "Close"
        case ..<0.7: return "A few miles"
        default: return "On the horizon"
        }
    }

    static func variationPreset(forEnergy energy: Double) -> Composer2Variation.Preset {
        switch Composer2Math.clamp01(energy) {
        case ..<0.2: return .exact
        case ..<0.4: return .subtle
        case ..<0.6: return .organic
        case ..<0.8: return .evolving
        default: return .wild
        }
    }

    /// Energy scales the composition's variation (0 = exact, 0.5 = as
    /// authored, 1 = doubled) without rewriting any layer's own settings —
    /// Layers-tab edits survive a Tune-tab drag.
    static func apply(energy: Double, to composition: inout Composer2Composition) {
        let e = Composer2Math.clamp01(energy)
        composition.master.energy = e
        composition.master.variation = e * 2
    }

    /// The word shown for an energy value.
    static func energyWord(_ energy: Double) -> String {
        switch Composer2Math.clamp01(energy) {
        case ..<0.1: return "Exact"
        case ..<0.35: return "Calm"
        case ..<0.65: return "As authored"
        case ..<0.9: return "Lively"
        default: return "Wild"
        }
    }
}
