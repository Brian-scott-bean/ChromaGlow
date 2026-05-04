// SceneColorBuilderView.swift
// CastChroma — P2 Scene Color Builder
//
// Full-screen scene design studio. Combines the 2D color pad, hue spectrum
// bar, harmony rule picker, and per-light assignment into a single cohesive
// experience.
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

    // Debounce
    @State private var previewTask: Task<Void, Never>?

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    private var isEditMode: Bool { existingSceneID != nil }

    // ── Computed ──────────────────────────────────────────────────

    private var canSave: Bool {
        !sceneName.trimmingCharacters(in: .whitespaces).isEmpty && !lights.isEmpty
    }

    /// True when ALL selected lights are color-capable.
    private var selectedSupportsColor: Bool {
        let selected = lights.filter { selectedLightIDs.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { $0.supportsColor }
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
            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        nameField
                            .padding(.top, 12)

                        harmonyPicker

                        lightStrip

                        if selectedSupportsColor {
                            colorControls
                        }

                        if selectedHasAmbiance {
                            colorTempSection
                        }

                        brightnessSection

                        saveButton
                            .padding(.top, 8)
                            .padding(.bottom, 48)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle(isEditMode ? "Edit Scene" : "New Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        revertLights()
                        dismiss()
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { setupInitialState() }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Background
    // ══════════════════════════════════════════════════════════════

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [
                        Color(hue: currentHue, saturation: 0.6, brightness: 0.8).opacity(0.18),
                        .clear
                    ],
                    center: .center, startRadius: 0, endRadius: 240
                ))
                .frame(width: 440)
                .offset(y: 100)
                .blur(radius: 30)
                .animation(.easeInOut(duration: 0.6), value: currentHue)
        }
        .ignoresSafeArea()
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Name Field
    // ══════════════════════════════════════════════════════════════

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCENE NAME")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            GlassmorphicCard(isActive: !sceneName.isEmpty, glowColor: amber) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundStyle(sceneName.isEmpty ? .white.opacity(0.3) : amber)

                    TextField("e.g. Movie Night, Sunset…", text: $sceneName)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .tint(amber)
                        .submitLabel(.done)

                    if !sceneName.isEmpty {
                        Button {
                            sceneName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Harmony Picker
    // ══════════════════════════════════════════════════════════════

    private var harmonyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HARMONY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HarmonyRule.allCases) { rule in
                        harmonyChip(rule)
                    }
                }
            }
        }
    }

    private func harmonyChip(_ rule: HarmonyRule) -> some View {
        let isSelected = harmonyRule == rule
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                harmonyRule = rule
            }
            HapticManager.shared.medium()
            applyHarmony()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: rule.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(rule.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? amber : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? .clear : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Light Strip
    // ══════════════════════════════════════════════════════════════

    private var lightStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LIGHTS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))

                Text("(\(selectedLightIDs.count)/\(lights.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber.opacity(0.8))

                Spacer()

                Button(selectedLightIDs.count == lights.count ? "Deselect All" : "Select All") {
                    withAnimation(.spring(response: 0.3)) {
                        if selectedLightIDs.count == lights.count {
                            selectedLightIDs = [lights.first?.id].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
                        } else {
                            selectedLightIDs = Set(lights.map(\.id))
                        }
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(amber)
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(lights.enumerated()), id: \.element.id) { idx, light in
                        lightChip(light: light, index: idx)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func lightChip(light: LightDisplayItem, index: Int) -> some View {
        let isSelected = selectedLightIDs.contains(light.id)
        let chipColor = lightColor(for: light)

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                if isSelected && selectedLightIDs.count > 1 {
                    selectedLightIDs.remove(light.id)
                } else if !isSelected {
                    selectedLightIDs.insert(light.id)
                }
            }
            // Sync color pad to this light's current color
            if let x = light.colorX, let y = light.colorY {
                let (h, s, b) = HueColorUtils.hsb(fromX: x, y: y, brightness: light.brightness)
                currentHue = h
                currentSaturation = s
                currentBrightness = max(0.1, b)
            }
            HapticManager.shared.soft()
        } label: {
            VStack(spacing: 6) {
                // Color dot
                ZStack {
                    Circle()
                        .fill(chipColor.opacity(0.25))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(chipColor)
                }

                // Name
                Text(light.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.45))
                    .lineLimit(1)
                    .frame(width: 65)

                // Brightness
                Text("\(Int(light.brightness))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chipColor.opacity(0.8))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? chipColor.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                isSelected ? chipColor.opacity(0.5) : .white.opacity(0.06),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .shadow(
                color: isSelected ? chipColor.opacity(0.35) : .clear,
                radius: 8, y: 4
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isSelected)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Color Controls
    // ══════════════════════════════════════════════════════════════

    private var colorControls: some View {
        VStack(spacing: 16) {
            // 2D Color Pad
            ColorPadView(
                hue: currentHue,
                saturation: $currentSaturation,
                brightness: $currentBrightness
            ) { sat, bri in
                applyColorToSelected(hue: currentHue, saturation: sat, brightness: bri)
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
        // Update light chips in real-time during pad drag (not just on commit)
        .onChange(of: currentSaturation) { _, newSat in
            updateLightChipsLive(hue: currentHue, saturation: newSat, brightness: currentBrightness)
        }
        .onChange(of: currentBrightness) { _, newBri in
            updateLightChipsLive(hue: currentHue, saturation: currentSaturation, brightness: newBri)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Color Temperature
    // ══════════════════════════════════════════════════════════════

    private var colorTempSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let kelvin = HueColorUtils.kelvin(from: currentMirek)
            Text("COLOR TEMPERATURE · \(kelvin)K")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            GlassmorphicCard(isActive: true, glowColor: HueColorUtils.color(fromMirek: currentMirek)) {
                ColorTempSlider(
                    currentMirek: currentMirek,
                    mirekMin: 153,
                    mirekMax: 500
                ) { mirek in
                    currentMirek = mirek
                    applyColorTempToSelected(mirek: mirek)
                }
                .padding(.vertical, 12)
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Brightness Slider
    // ══════════════════════════════════════════════════════════════

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BRIGHTNESS · \(Int(displayBrightness))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            GlassmorphicCard(isActive: true, glowColor: amber) {
                BrightnessRow(
                    brightness: displayBrightness,
                    glowColor: amber,
                    onCommit: { newBrightness in
                        displayBrightness = newBrightness
                        applyBrightnessToSelected(percent: newBrightness)
                    }
                )
                .padding(.vertical, 12)
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Save Button
    // ══════════════════════════════════════════════════════════════

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(canSave
                          ? LinearGradient(
                                colors: [amber.opacity(0.85), amber],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(
                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 54)
                    .shadow(color: canSave ? amber.opacity(0.45) : .clear, radius: 14)

                if isSaving {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color(red: 0.08, green: 0.07, blue: 0.14))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: isEditMode ? "pencil" : "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                        Text(isEditMode
                             ? "Update Scene"
                             : "Save Scene (\(lights.count) light\(lights.count == 1 ? "" : "s"))")
                            .font(.headline)
                    }
                    .foregroundStyle(canSave
                                     ? Color(red: 0.09, green: 0.08, blue: 0.14)
                                     : .white.opacity(0.25))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSave || isSaving)
        .animation(.spring(response: 0.3), value: canSave)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Logic
    // ══════════════════════════════════════════════════════════════

    private func setupInitialState() {
        lights = initialLights
        originalLights = initialLights
        selectedLightIDs = Set(initialLights.map(\.id))

        // Seed color from first light
        if let first = initialLights.first, let x = first.colorX, let y = first.colorY {
            let (h, s, b) = HueColorUtils.hsb(fromX: x, y: y, brightness: first.brightness)
            currentHue = h
            currentSaturation = s
            currentBrightness = max(0.1, b)
        }
        if let first = initialLights.first, let mirek = first.colorTempMirek {
            currentMirek = mirek
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
            // Harmony: update all color-capable lights with derived palette
            let colorLights = lights.indices.filter { lights[$0].supportsColor }
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

    /// Apply the current harmony rule across all lights.
    private func applyHarmony() {
        guard harmonyRule != .none else { return }

        let colorLights = lights.indices.filter { lights[$0].supportsColor }
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

        // Select all so the preview covers everything
        selectedLightIDs = Set(lights.map(\.id))
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

        // Stagger updates across lights to avoid overwhelming the bridge.
        for light in lights where selectedLightIDs.contains(light.id) {
            if light.supportsColor, let x = light.colorX, let y = light.colorY {
                try? await api.setLightColor(id: light.id, x: x, y: y)
            } else if light.supportsColorTemp, let mirek = light.colorTempMirek {
                try? await api.setLightColorTemp(id: light.id, mirek: mirek)
            }
            // Small stagger between lights
            try? await Task.sleep(for: .milliseconds(50))
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
        return amber
    }
}
