// SceneColorBuilderView.swift
// ChromaGlow — Scene Color Builder (Luminous)
//
// Full-screen scene design studio: a stage that shows the room's lights as
// you paint them, then the 2D color pad, hue spectrum bar, harmony rule
// picker and per-light assignment — one cohesive instrument.
//
// Supports both CREATE and EDIT modes:
//   • Create: lights arrive with their current state; user designs new palette.
//   • Edit:   lights arrive pre-loaded with the existing scene's per-light colors.
//
// Live preview: every color change is debounced and sent to the real bulbs
// so the user sees their room transform in real-time.

import SwiftUI

// MARK: - SceneColorBuilderView

struct SceneColorBuilderView: View {

    // ── Injected ──────────────────────────────────────────────────
    let roomID: String
    let roomRType: String           // "room" or "zone"
    let bridgeID: String
    /// Nil = create mode; non-nil = edit mode (existing scene UUID).
    let existingSceneID: String?
    /// Scene name to pre-populate in edit mode.
    let existingSceneName: String?
    /// The initial light states. In edit mode, these should be pre-seeded
    /// with the scene's per-light colors.
    let initialLights: [LightDisplayItem]

    /// Called on successful save/update. Parent dismisses the sheet.
    let onSave: () -> Void

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    // ── State ─────────────────────────────────────────────────────
    @State private var sceneName: String = ""
    @State private var lights: [LightDisplayItem] = []
    /// IDs of currently selected lights (color changes apply to these).
    @State private var selectedLightIDs: Set<String> = []
    /// Snapshot of light states on entry — used to revert on cancel.
    @State private var originalLights: [LightDisplayItem] = []

    // Color state
    @State private var currentHue: Double = 0.0
    @State private var currentSaturation: Double = 1.0
    @State private var currentBrightness: Double = 1.0
    @State private var currentMirek: Int = 300

    // Harmony
    @State private var harmonyRule: HarmonyRule = .none

    // UI state
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var displayBrightness: Double = 100  // % label value
    /// Pad brightness the slider just wrote — its onChange echo is skipped.
    @State private var sliderBrightnessEcho: Double?

    // Debounce
    @State private var previewTask: Task<Void, Never>?

    /// Edit mode reads the scene's own stored actions before anything is
    /// editable (see `seedFromSceneIfEditing`).
    private enum SceneSeed: Equatable { case notNeeded, loading, loaded, failed }
    @State private var sceneSeed: SceneSeed = .notNeeded

    /// The color the pad is on — the builder's own accent.
    private var padColor: Color { Color(hue: currentHue, saturation: max(0.35, currentSaturation), brightness: 1) }

    private var isEditMode: Bool { existingSceneID != nil }

    // ── Computed ──────────────────────────────────────────────────

    private var canSave: Bool {
        let name = sceneName.trimmingCharacters(in: .whitespaces)
        // Never save an edit that wasn't seeded from the scene itself — the
        // live room state it would fall back to may be the PREVIOUS look.
        let seedOK = sceneSeed != .loading && sceneSeed != .failed
        return !name.isEmpty && name.count <= 32 && !lights.isEmpty && seedOK
    }

    /// True when ANY selected light is color-capable (show the pad).
    private var selectedSupportsColor: Bool {
        let selected = lights.filter { selectedLightIDs.contains($0.id) }
        return selected.contains { $0.supportsColor }
    }

    /// True when at least one selected light supports only color temp (no full color).
    private var selectedHasAmbiance: Bool {
        let selected = lights.filter { selectedLightIDs.contains($0.id) }
        return selected.contains { !$0.supportsColor && $0.supportsColorTemp }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Body
    // ══════════════════════════════════════════════════════════════

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                // While an edit's scene is being read, the controls are
                // NOT in the hierarchy: they mount afterwards with the
                // seeded values as their initial state, so the pad's
                // live-sync onChange handlers never fire for the seed
                // (which would paint every light the first light's color).
                if sceneSeed == .loading {
                    VStack(spacing: 14) {
                        ProgressView().tint(LuminousPalette.ink)
                        Text("Reading scene…")
                            .font(.subheadline)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        LuminousScreenTitle(title: isEditMode ? "Edit scene" : "New scene",
                                            eyebrow: "Build colors",
                                            eyebrowSymbol: "paintpalette.fill",
                                            eyebrowTint: padColor,
                                            subtitle: "Pick a light, paint it. Hold a light to paint several at once.")
                            .padding(.top, 4)

                        stage

                        nameField

                        harmonyPicker

                        lightStrip

                        if selectedSupportsColor {
                            colorControls
                            myColorsStrip
                        }

                        if selectedHasAmbiance {
                            colorTempSection
                        }

                        brightnessSection

                        LuminousPrimaryButton(title: isEditMode
                                                ? "Update Scene"
                                                : "Save Scene (\(lights.count) light\(lights.count == 1 ? "" : "s"))",
                                              symbol: isEditMode ? "pencil" : "sparkles",
                                              busy: isSaving) {
                            Task { await save() }
                        }
                        .disabled(!canSave || isSaving)
                        .animation(.spring(response: 0.3), value: canSave)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, HueSpacing.screenH)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background { LuminousAmbience(colors: ambienceColors) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        revertLights()
                        dismiss()
                    }
                    .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
            }
            .onAppear { setupInitialState() }
            .task { await seedFromSceneIfEditing() }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .luminousSheet()
    }

    /// The colors the lights are being painted, for the background glow.
    private var ambienceColors: [Color] {
        let lit = LuminousLight.palette(of: lights, max: 3)
        return lit.isEmpty ? [padColor] : lit
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Stage
    // ══════════════════════════════════════════════════════════════

    /// The room as it will look: every light as an orb in the color it is
    /// being painted, redrawn as the pad moves.
    private var stage: some View {
        LuminousMiniRoomStage(lights: lights, height: 104)
            .padding(.vertical, 6)
            .luminousStageFrame(radius: 24)
            .accessibilityElement()
            .accessibilityLabel("Preview of \(lights.count) light\(lights.count == 1 ? "" : "s")")
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Name Field
    // ══════════════════════════════════════════════════════════════

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "Scene name").padding(.horizontal, 6)
            // Hue bridge limits scene names to 32 characters.
            LuminousTextField(placeholder: "e.g. Movie Night, Sunset…", text: $sceneName,
                              symbol: "sparkles", tint: padColor, limit: 32)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Harmony Picker
    // ══════════════════════════════════════════════════════════════

    private var harmonyPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "Harmony").padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HarmonyRule.allCases) { rule in
                        LuminousChip(title: rule.rawValue, symbol: rule.icon,
                                     selected: harmonyRule == rule, accent: padColor) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                harmonyRule = rule
                            }
                            applyHarmony()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Light Strip
    // ══════════════════════════════════════════════════════════════

    private var lightStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LuminousEyebrow(text: "Lights")
                Text("\(selectedLightIDs.count) of \(lights.count)")
                    .font(LuminousType.value)
                    .foregroundStyle(padColor)
                Spacer()
                Button(selectedLightIDs.count == lights.count ? "Deselect All" : "Select All") {
                    withAnimation(.spring(response: 0.3)) {
                        if selectedLightIDs.count == lights.count {
                            selectedLightIDs = [lights.first?.id].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
                        } else {
                            selectedLightIDs = Set(lights.map(\.id))
                        }
                    }
                    HapticManager.shared.selection()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LuminousPalette.cyan)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(lights.enumerated()), id: \.element.id) { idx, light in
                        lightChip(light: light, index: idx)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    private func lightChip(light: LightDisplayItem, index: Int) -> some View {
        let isSelected = selectedLightIDs.contains(light.id)
        let chipColor = lightColor(for: light)
        let level = light.isOn ? max(0.15, light.brightness / 100) : 0

        return VStack(spacing: 7) {
            // The light as an orb: its color, glowing at its brightness.
            Circle()
                .fill(light.isOn
                      ? AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.35 + 0.6 * level), chipColor],
                                                     center: .init(x: 0.38, y: 0.32),
                                                     startRadius: 0, endRadius: 22))
                      : AnyShapeStyle(Color.white.opacity(0.06)))
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Color.white.opacity(light.isOn ? 0.3 : 0.16), lineWidth: 1))
                .shadow(color: chipColor.opacity(light.isOn ? 0.75 * level : 0), radius: 12)
                .frame(width: 48, height: 44)

            Text(light.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink.opacity(isSelected ? 0.95 : 0.55))
                .lineLimit(1)
                .frame(width: 70)

            Text("\(BrightnessDisplay.percent(light.brightness))%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(LuminousPalette.inkSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .luminousGlass(radius: 18, accent: chipColor, selected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // ── Tap: single-select (paint mode) ──
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                selectedLightIDs = [light.id]
            }
            syncPadToLight(light)
            HapticManager.shared.soft()
        }
        // ── Long press: multi-select toggle ──
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isSelected && selectedLightIDs.count > 1 {
                    // Deselect this light
                    selectedLightIDs.remove(light.id)
                } else if !isSelected {
                    // Add this light to selection
                    selectedLightIDs.insert(light.id)
                }
                // If it's the only one selected, long press keeps it (can't deselect all)
            }
            HapticManager.shared.medium()
        }
        .animation(.spring(response: 0.25), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(light.name), \(BrightnessDisplay.percent(light.brightness)) percent")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint("Double tap to paint this light alone. Hold to add it to the lights being painted.")
    }

    /// Sync the color pad & brightness slider to a specific light's state.
    private func syncPadToLight(_ light: LightDisplayItem) {
        if let x = light.colorX, let y = light.colorY {
            let (h, s, _) = HueColorUtils.hsb(fromX: x, y: y, brightness: light.brightness)
            currentHue = h
            currentSaturation = s
            currentBrightness = Self.padBrightness(percent: light.brightness)
        }
        displayBrightness = light.brightness
    }

    /// The pad's Y axis for a light: its REAL brightness. `hsb(fromX:)`'s
    /// `b` is the normalised RGB peak — ~1.0 for any saturated color at any
    /// dimming — and the pad's live sync wrote it back to the bulb, so merely
    /// tapping a light chip jumped it to 100%.
    nonisolated static func padBrightness(percent: Double) -> Double {
        min(1, max(0.01, percent / 100))
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Color Controls
    // ══════════════════════════════════════════════════════════════

    private var colorControls: some View {
        VStack(spacing: 16) {
            // 2D Color Pad (the "SB Pad")
            ColorPadView(
                hue: currentHue,
                saturation: $currentSaturation,
                brightness: $currentBrightness
            ) { sat, bri in
                // Harmony-aware commit: use palette, not single color
                if harmonyRule != .none {
                    applyHarmony()
                } else {
                    applyColorToSelected(hue: currentHue, saturation: sat, brightness: bri)
                }
                // Keep brightness slider in sync with pad Y-axis
                displayBrightness = max(1, bri * 100)
            }

            // Hue Spectrum Bar
            HueSpectrumBar(
                hue: $currentHue,
                harmonyRule: harmonyRule
            ) { newHue in
                if harmonyRule != .none {
                    applyHarmony()
                } else {
                    applyColorToSelected(hue: newHue, saturation: currentSaturation, brightness: currentBrightness)
                }
            }
        }
        .padding(14)
        .luminousPanel(glow: padColor, glowStrength: 0.45)
        // Update light chips in real-time during pad drag (not just on commit)
        .onChange(of: currentSaturation) { _, newSat in
            updateLightChipsLive(hue: currentHue, saturation: newSat, brightness: currentBrightness)
        }
        .onChange(of: currentBrightness) { _, newBri in
            // The brightness slider moved the pad to match — it already
            // applied brightness alone; a live sync here would also repaint
            // every selected light the pad's color.
            if let echo = sliderBrightnessEcho {
                sliderBrightnessEcho = nil
                if echo == newBri { return }
            }
            updateLightChipsLive(hue: currentHue, saturation: currentSaturation, brightness: newBri)
        }
        .onChange(of: currentHue) { _, newHue in
            updateLightChipsLive(hue: newHue, saturation: currentSaturation, brightness: currentBrightness)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - My Colors (saved palette)
    // ══════════════════════════════════════════════════════════════

    /// Saved palette: ＋ captures the pad's current color, a swatch tap
    /// paints the selected lights through the existing preview pipeline.
    private var myColorsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: "My colors").padding(.horizontal, 6)
            SavedColorStrip(
                onSave: {
                    let (x, y) = HueColorUtils.xyFrom(
                        hue: currentHue, saturation: currentSaturation, brightness: 1
                    )
                    SavedColorStore.shared.add(SavedColor(
                        x: x, y: y, brightness: max(1, currentBrightness * 100)
                    ))
                    HapticManager.shared.success()
                },
                onTapSwatch: { saved in
                    if let x = saved.x, let y = saved.y {
                        let (h, s, _) = HueColorUtils.hsb(fromX: x, y: y,
                                                          brightness: saved.brightness)
                        currentHue = h
                        currentSaturation = s
                        currentBrightness = max(0.1, saved.brightness / 100)
                        applyColorToSelected(hue: h, saturation: s,
                                             brightness: currentBrightness)
                    } else if let mirek = saved.mirek {
                        applyColorTempToSelected(mirek: mirek)
                    }
                    HapticManager.shared.medium()
                }
            )
            .padding(.vertical, 4)
            .luminousGlass(radius: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Color Temperature
    // ══════════════════════════════════════════════════════════════

    private var colorTempSection: some View {
        let kelvin = HueColorUtils.kelvin(from: currentMirek)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HueColorUtils.color(fromMirek: currentMirek))
                Text("Warmth")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink.opacity(0.9))
                Spacer(minLength: 0)
                Text("\(kelvin)K")
                    .font(LuminousType.value)
                    .foregroundStyle(LuminousPalette.ink.opacity(0.7))
            }
            ColorTempSlider(
                currentMirek: currentMirek,
                mirekMin: 153,
                mirekMax: 500
            ) { mirek in
                currentMirek = mirek
                applyColorTempToSelected(mirek: mirek)
            }
        }
        .padding(16)
        .luminousPanel(glow: HueColorUtils.color(fromMirek: currentMirek), glowStrength: 0.5)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Brightness Slider
    // ══════════════════════════════════════════════════════════════

    private var brightnessSection: some View {
        LuminousGlowSlider(title: "Brightness",
                           symbol: "sun.max.fill",
                           value: $displayBrightness,
                           range: 1...100,
                           colors: [padColor.opacity(0.35), padColor, .white],
                           format: { "\(BrightnessDisplay.percent($0))%" },
                           onEditingChanged: { editing in
                               guard !editing else { return }
                               HapticManager.shared.heavy()
                               // Keep the pad's Y axis in step, or the next pad/hue
                               // move re-sends the OLD brightness and undoes this.
                               let padValue = Self.padBrightness(percent: displayBrightness)
                               if padValue != currentBrightness {
                                   sliderBrightnessEcho = padValue
                                   currentBrightness = padValue
                               }
                               applyBrightnessToSelected(percent: displayBrightness)
                           })
            .padding(16)
            .luminousGlass()
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Logic
    // ══════════════════════════════════════════════════════════════

    private func setupInitialState() {
        // An edit whose scene already arrived keeps its seeded lights.
        if sceneSeed != .loaded { lights = initialLights }
        originalLights = initialLights
        selectedLightIDs = Set(initialLights.map(\.id))

        // Pre-populate scene name in edit mode
        if isEditMode, let name = existingSceneName {
            sceneName = name
        }

        seedPad(from: lights)
    }

    /// Point the pad, warmth slider, and brightness slider at a light set.
    private func seedPad(from seedLights: [LightDisplayItem]) {
        // Seed color from first light
        if let first = seedLights.first, let x = first.colorX, let y = first.colorY {
            let (h, s, _) = HueColorUtils.hsb(fromX: x, y: y, brightness: first.brightness)
            currentHue = h
            currentSaturation = s
            currentBrightness = Self.padBrightness(percent: first.brightness)
        }
        if let first = seedLights.first, let mirek = first.colorTempMirek {
            currentMirek = mirek
        }
        // Seed brightness slider from average of all lights
        if !seedLights.isEmpty {
            let avg = seedLights.reduce(0.0) { $0 + $1.brightness } / Double(seedLights.count)
            displayBrightness = max(1, avg)
        }
    }

    /// Edit mode: seed every light from the scene's OWN stored actions.
    ///
    /// The callers activate the scene and open the builder straight away, so
    /// `initialLights` (the room's live state) is usually still the PREVIOUS
    /// look — the activation refresh lands ~0.5 s later — and saving then
    /// overwrote the scene with it. Reading the scene removes that race; a
    /// failed read blocks saving rather than falling back to live state.
    private func seedFromSceneIfEditing() async {
        guard let sceneID = existingSceneID, !orchestrator.isDemoMode else { return }
        sceneSeed = .loading
        guard let api = orchestrator.hueClient(for: bridgeID) else {
            sceneSeed = .failed
            errorMessage = "Couldn't reach the bridge to read this scene. Close and try again."
            return
        }
        do {
            let detail = try await api.fetchSceneDetail(id: sceneID)
            let seeded = Self.seeded(initialLights, from: detail.actions ?? [])
            lights = seeded
            seedPad(from: seeded)
            sceneSeed = .loaded
        } catch {
            sceneSeed = .failed
            errorMessage = "Couldn't read this scene from the bridge, so it can't be edited safely. Close and try again."
        }
    }

    /// Pure: each light takes its stored scene action; lights the scene
    /// doesn't mention keep their live state. Mirrors how `updateScene`
    /// writes back (xy wins when present, else CT) so an untouched edit
    /// saves the scene unchanged: a color action clears mirek, a CT action
    /// clears xy.
    nonisolated static func seeded(_ lights: [LightDisplayItem],
                                   from actions: [SceneActionDetail]) -> [LightDisplayItem] {
        var byLight: [String: SceneActionState] = [:]
        for action in actions where action.target.rtype == "light" {
            if byLight[action.target.rid] == nil { byLight[action.target.rid] = action.action }
        }
        return lights.map { light in
            guard let action = byLight[light.id] else { return light }
            var seeded = light
            if let on = action.on?.on { seeded.isOn = on }
            if let brightness = action.dimming?.brightness {
                seeded.brightness = min(100, max(1, brightness))
            }
            if let xy = action.color?.xy {
                seeded.colorX = xy.x
                seeded.colorY = xy.y
                seeded.colorTempMirek = nil
            } else if let mirek = action.color_temperature?.mirek {
                seeded.colorTempMirek = mirek
                seeded.colorX = nil
                seeded.colorY = nil
            }
            return seeded
        }
    }

    // MARK: Apply Color

    /// Apply a color to all selected lights (updates local model + live preview).
    private func applyColorToSelected(hue: Double, saturation: Double, brightness: Double) {
        let (x, y) = HueColorUtils.xyFrom(hue: hue, saturation: saturation, brightness: 1)
        let brightnessPercent = max(1, brightness * 100)

        for i in lights.indices {
            guard selectedLightIDs.contains(lights[i].id), lights[i].supportsColor else { continue }
            lights[i].colorX = x
            lights[i].colorY = y
            lights[i].brightness = brightnessPercent
            lights[i].isOn = true
        }

        debouncedPreview()
    }

    /// Apply color temperature to all selected ambiance lights.
    private func applyColorTempToSelected(mirek: Int) {
        for i in lights.indices {
            guard selectedLightIDs.contains(lights[i].id),
                  !lights[i].supportsColor,
                  lights[i].supportsColorTemp else { continue }
            lights[i].colorTempMirek = mirek
            lights[i].isOn = true
        }

        debouncedPreview()
    }

    /// Apply brightness to all selected lights.
    private func applyBrightnessToSelected(percent: Double) {
        let clamped = max(1, min(100, percent))
        for i in lights.indices {
            guard selectedLightIDs.contains(lights[i].id) else { continue }
            lights[i].brightness = clamped
            lights[i].isOn = true
        }
        debouncedPreview()
    }

    /// Update light chip colors in real-time during pad drag (local model only, no API).
    /// The debounced preview handles the bridge communication.
    private func updateLightChipsLive(hue: Double, saturation: Double, brightness: Double) {
        if harmonyRule != .none {
            // Harmony: update only SELECTED color-capable lights with derived palette
            let colorLights = lights.indices.filter {
                lights[$0].supportsColor && selectedLightIDs.contains(lights[$0].id)
            }
            guard !colorLights.isEmpty else { return }
            let palette = HarmonyEngine.palette(
                rule: harmonyRule, rootHue: hue,
                saturation: saturation, brightness: brightness,
                count: colorLights.count
            )
            for (i, idx) in colorLights.enumerated() {
                let pc = palette[i]
                let (x, y) = HueColorUtils.xyFrom(hue: pc.hue, saturation: pc.saturation, brightness: 1)
                lights[idx].colorX = x
                lights[idx].colorY = y
                lights[idx].brightness = max(1, pc.brightness * 100)
            }
        } else {
            // Manual: update only selected lights
            let (x, y) = HueColorUtils.xyFrom(hue: hue, saturation: saturation, brightness: 1)
            let brightnessPercent = max(1, brightness * 100)
            for i in lights.indices {
                guard selectedLightIDs.contains(lights[i].id), lights[i].supportsColor else { continue }
                lights[i].colorX = x
                lights[i].colorY = y
                lights[i].brightness = brightnessPercent
            }
        }
        debouncedPreview()
    }

    // MARK: Harmony

    /// Apply the current harmony rule to the SELECTED lights only.
    /// Unselected lights keep their existing colors — enabling layered
    /// scene design (e.g. Triad on 3 lights + Analogous on 2 others).
    private func applyHarmony() {
        guard harmonyRule != .none else { return }

        let colorLights = lights.indices.filter {
            lights[$0].supportsColor && selectedLightIDs.contains(lights[$0].id)
        }
        guard !colorLights.isEmpty else { return }

        let palette = HarmonyEngine.palette(
            rule: harmonyRule,
            rootHue: currentHue,
            saturation: currentSaturation,
            brightness: currentBrightness,
            count: colorLights.count
        )

        for (i, idx) in colorLights.enumerated() {
            let pc = palette[i]
            let (x, y) = HueColorUtils.xyFrom(hue: pc.hue, saturation: pc.saturation, brightness: 1)
            lights[idx].colorX = x
            lights[idx].colorY = y
            lights[idx].brightness = max(1, pc.brightness * 100)
            lights[idx].isOn = true
        }

        debouncedPreview()
    }

    // MARK: Live Preview

    /// Debounce live preview — sends color to real bulbs.
    /// Max 10 req/sec per the Hue bridge spec.
    private func debouncedPreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await sendPreview()
        }
    }

    /// Send current light states to the bridge for live preview.
    private func sendPreview() async {
        guard let api = orchestrator.hueClient(for: bridgeID) else { return }
        // ONE PUT per light — on + dimming + color/CT together (it used to be
        // three sequential requests per light: on, color, brightness) — paced
        // through the bridge's shared BridgeCommandGate so a preview burst
        // stays inside the ~10 cmd/s budget alongside every other writer.
        // No retry: a newer preview supersedes a failed frame, and a newer
        // preview cancels this task, which stops the gate sending stale ones.
        let gate = orchestrator.commandGate(for: bridgeID)
        for light in lights where selectedLightIDs.contains(light.id) {
            guard !Task.isCancelled else { return }
            let id = light.id
            let brightness = light.brightness
            var xy: (Double, Double)? = nil
            if light.supportsColor, let x = light.colorX, let y = light.colorY { xy = (x, y) }
            let mirek: Int? = (xy == nil && light.supportsColorTemp) ? light.colorTempMirek : nil
            let sendXY = xy
            await gate.send(retry: false) {
                // on:true — color/brightness on an off light has no visible effect.
                try await api.setLightEffect(id: id, on: true, brightness: brightness,
                                             xy: sendXY, mirek: mirek, duration: 0)
            }
        }
    }

    // MARK: Revert

    /// Revert lights to their original state (cancel flow).
    private func revertLights() {
        previewTask?.cancel()
        Task {
            guard let api = orchestrator.hueClient(for: bridgeID) else { return }
            for light in originalLights {
                if light.supportsColor, let x = light.colorX, let y = light.colorY {
                    try? await api.setLightColor(id: light.id, x: x, y: y)
                    try? await api.setLightBrightness(id: light.id, brightness: light.brightness)
                } else if light.supportsColorTemp, let mirek = light.colorTempMirek {
                    try? await api.setLightColorTemp(id: light.id, mirek: mirek)
                }
                if !light.isOn {
                    try? await api.setLight(id: light.id, on: false)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: Save

    private func save() async {
        let name = sceneName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Family Sharing backstop: the create path POSTs straight to the
        // bridge client (no orchestrator refusal on the way), so a granted
        // bridge is refused here as well as at every entry point.
        guard !orchestrator.isGuestGrantedBridge(bridgeID) else {
            errorMessage = "Not available with guest access"
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            if let sceneID = existingSceneID {
                // Edit mode: update existing scene
                try await orchestrator.updateScene(
                    sceneID: sceneID,
                    bridgeID: bridgeID,
                    name: name,
                    lights: lights
                )
            } else {
                // Create mode
                let request = CreateSceneRequest.fromCurrentLights(
                    name: name,
                    groupID: roomID,
                    groupRtype: roomRType,
                    lights: lights
                )
                guard let api = orchestrator.hueClient(for: bridgeID) else {
                    throw NSError(domain: "SceneBuilder", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No bridge connection"])
                }
                try await api.createScene(request)
            }

            HapticManager.shared.success()
            await orchestrator.loadAllScenes()
            onSave()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            HapticManager.shared.error()
        }
    }

    // MARK: Helpers

    private func lightColor(for light: LightDisplayItem) -> Color {
        if let x = light.colorX, let y = light.colorY {
            return HueColorUtils.color(fromX: x, y: y, brightness: light.brightness)
        }
        if let mirek = light.colorTempMirek {
            return HueColorUtils.color(fromMirek: mirek)
        }
        return LuminousLight.color(of: light)
    }
}
