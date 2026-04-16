// CreateSceneView.swift
// HueHome Pro — Story 4.2
//
// Glassmorphic sheet for saving the current room's light state as a named scene.
// Presented from the "+" button in the scene strip.
//
// Flow:
//  1. User arranges lights to the desired look in RoomDetailView.
//  2. Taps "+" → this sheet slides up.
//  3. Types a scene name → taps "Save Scene".
//  4. Bridge stores the scene; strip reloads showing the new chip.

import SwiftUI

struct CreateSceneView: View {

    // Injected from parent
    let lights: [LightDisplayItem]
    let onSave: (String) async -> Bool   // returns true on success

    @Environment(\.dismiss) private var dismiss

    @State private var sceneName:   String = ""
    @State private var isSaving:    Bool   = false
    @State private var saveFailed:  Bool   = false
    @FocusState private var nameFocused: Bool

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        nameField
                        lightPreview
                        saveButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("New Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { nameFocused = true }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [amber.opacity(0.16), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 340)
                .offset(x: 100, y: -200)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Name Field
    // ──────────────────────────────────────────────

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCENE NAME")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            GlassmorphicCard(isActive: !sceneName.isEmpty, glowColor: amber) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundStyle(sceneName.isEmpty ? .white.opacity(0.3) : amber)

                    TextField("e.g. Movie Night, Relax…", text: $sceneName)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .tint(amber)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { if canSave { Task { await save() } } }

                    if !sceneName.isEmpty {
                        Button {
                            sceneName = ""
                            nameFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if saveFailed {
                Text("Scene could not be saved — check the console for details.")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.top, 2)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Light Preview
    // ──────────────────────────────────────────────

    private var lightPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIGHT STATES TO CAPTURE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            GlassmorphicCard(isActive: false, glowColor: amber) {
                VStack(spacing: 0) {
                    let built = previewRows
                    built
                }
            }
        }
    }

    private var previewRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(lights.enumerated()), id: \.element.id) { idx, light in
                HStack(spacing: 12) {
                    // Color swatch / on indicator
                    ZStack {
                        Circle()
                            .fill(light.isOn
                                  ? swatchColor(for: light).opacity(0.28)
                                  : Color.white.opacity(0.06))
                            .frame(width: 36, height: 36)
                        Image(systemName: archetypeIcon(for: light.archetype))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(light.isOn
                                             ? swatchColor(for: light)
                                             : .white.opacity(0.25))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(light.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(light.isOn ? .white : .white.opacity(0.45))
                            .lineLimit(1)

                        Text(light.isOn
                             ? "\(Int(light.brightness))% · \(lightStateLabel(light))"
                             : "Off — will be off in scene")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.40))
                    }

                    Spacer()

                    // On/Off pill
                    Text(light.isOn ? "ON" : "OFF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(light.isOn ? amber : .white.opacity(0.2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(light.isOn ? amber.opacity(0.15) : Color.white.opacity(0.06))
                        )
                }
                .padding(.vertical, 10)

                if idx < lights.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.07))
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Save Button
    // ──────────────────────────────────────────────

    private var canSave: Bool { !sceneName.trimmingCharacters(in: .whitespaces).isEmpty }

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
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Save Scene")
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

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    private func save() async {
        let name = sceneName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        isSaving   = true
        saveFailed = false

        let success = await onSave(name)

        if success {
            HapticManager.shared.success()
            dismiss()
        } else {
            isSaving   = false
            saveFailed = true
            HapticManager.shared.error()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func swatchColor(for light: LightDisplayItem) -> Color {
        if let x = light.colorX, let y = light.colorY {
            return Color(hue: xyToHue(x: x, y: y), saturation: 0.75, brightness: 1.0)
        }
        return amber
    }

    private func lightStateLabel(_ light: LightDisplayItem) -> String {
        if light.colorX != nil { return "Color" }
        if let mirek = light.colorTempMirek {
            return "\(HueColorUtils.kelvin(from: mirek))K"
        }
        return "White"
    }

    /// Rough CIE xy → hue approximation for swatch display only.
    private func xyToHue(x: Double, y: Double) -> Double {
        let r =  x * 3.1338561 - y * 1.6168667 - 0.4906146
        let g = -x * 0.9787684 + y * 1.9161415 + 0.0334540
        let b =  x * 0.0719453 - y * 0.2289914 + 1.4052427
        let maxC = max(r, g, b)
        guard maxC > 0 else { return 0 }
        let nr = r / maxC; let ng = g / maxC; let nb = b / maxC
        if nr >= ng && nr >= nb { return (ng - nb) / (6.0 * (nr - min(ng, nb) + 0.0001)) }
        if ng >= nr && ng >= nb { return (2.0 + (nb - nr) / (6.0 * (ng - min(nr, nb) + 0.0001))) / 6 }
        return (4.0 + (nr - ng) / (6.0 * (nb - min(nr, ng) + 0.0001))) / 6
    }
}
