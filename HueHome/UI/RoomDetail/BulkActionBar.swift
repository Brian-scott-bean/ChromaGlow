// BulkActionBar.swift
// ChromaGlow — Room (Luminous): the dock for several lights at once.
//
// Floats above the tab bar while lights are selected — the Composer's dock
// language: a count and All/None, then On · Off · Brightness · Scene.
// Every write goes through the view model's paced bulk path.

import SwiftUI

struct BulkActionBar: View {

    @Bindable var vm: RoomDetailViewModel
    /// Opens the scene builder pre-filtered to the selected lights.
    var onCreateScene: () -> Void

    @State private var showBrightnessSheet = false
    @State private var bulkBrightness: Double = 80

    init(vm: RoomDetailViewModel, onCreateScene: @escaping () -> Void) {
        self.vm            = vm
        self.onCreateScene = onCreateScene
    }

    private var count: Int { vm.selectedLightIDs.count }
    private var allSelected: Bool { count == vm.lights.count }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LuminousPalette.cyan)
                Text("\(count) light\(count == 1 ? "" : "s") selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                LuminousTextPill(title: allSelected ? "None" : "All", tint: LuminousPalette.cyan) {
                    if allSelected { vm.clearSelection() } else { vm.selectAll() }
                }
                .accessibilityLabel(allSelected ? "Select none" : "Select all")
            }
            HStack(spacing: 8) {
                LuminousDockButton(title: "On", symbol: "sun.max.fill", tint: LuminousPalette.amber) {
                    HapticManager.shared.light()
                    vm.setSelectedLightsOn(true)
                }
                LuminousDockButton(title: "Off", symbol: "moon.fill") {
                    HapticManager.shared.light()
                    vm.setSelectedLightsOn(false)
                }
                LuminousDockButton(title: "Brightness", symbol: "slider.horizontal.3") {
                    // Seed the slider with the selection's average brightness.
                    let selected = vm.selectedLights
                    if !selected.isEmpty {
                        bulkBrightness = selected.map(\.brightness).reduce(0, +) / Double(selected.count)
                    }
                    showBrightnessSheet = true
                }
                LuminousDockButton(title: "Scene", symbol: "camera.aperture", tint: LuminousPalette.cyan,
                                   highlighted: true) {
                    onCreateScene()
                }
            }
            .disabled(count == 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .luminousDock()
        .sheet(isPresented: $showBrightnessSheet) {
            brightnessSheet
                .presentationDetents([.fraction(0.34)])
                .luminousSheet()
        }
    }

    // MARK: - Brightness sheet

    private var brightnessSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            LuminousSectionHeader(title: "Brightness",
                                  subtitle: "For the \(count) selected light\(count == 1 ? "" : "s").")
            LuminousGlowSlider(title: "Level",
                               symbol: "sun.max.fill",
                               value: $bulkBrightness,
                               range: 1...100,
                               colors: [LuminousPalette.amber.opacity(0.5), LuminousPalette.amber],
                               format: { "\(BrightnessDisplay.percent($0))%" },
                               accessibilityName: "Brightness for the selected lights")
            LuminousPrimaryButton(title: "Apply to \(count) light\(count == 1 ? "" : "s")", symbol: "checkmark") {
                vm.setSelectedLightsBrightness(bulkBrightness)
                showBrightnessSheet = false
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
}
