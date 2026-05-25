// BulkActionBar.swift
// ChromaGlow — Story 5.1 (multi-select bulk control)
//
// Floating glassmorphic action bar that slides up from the bottom
// of RoomDetailView when one or more lights are selected.
//
// Actions: On · Off · Brightness (compact sheet) · Create Scene from selection

import SwiftUI

struct BulkActionBar: View {

    @Bindable var vm: RoomDetailViewModel
    /// Triggers CreateSceneView pre-filtered to the selected lights.
    var onCreateScene: () -> Void

    @State private var showBrightnessSheet = false
    @State private var bulkBrightness: Double = 80

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)
    private let count: Int

    init(vm: RoomDetailViewModel, onCreateScene: @escaping () -> Void) {
        self.vm            = vm
        self.onCreateScene = onCreateScene
        self.count         = vm.selectedLightIDs.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Selection count label
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(amber)
                Text("\(vm.selectedLightIDs.count) light\(vm.selectedLightIDs.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                // Select All / None
                Button(vm.selectedLightIDs.count == vm.lights.count ? "None" : "All") {
                    if vm.selectedLightIDs.count == vm.lights.count {
                        vm.clearSelection()
                    } else {
                        vm.selectAll()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(amber)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            // Action buttons
            HStack(spacing: 0) {
                actionButton(icon: "sun.max.fill", label: "On", color: amber) {
                    vm.setSelectedLightsOn(true)
                }

                divider

                actionButton(icon: "moon.fill", label: "Off", color: .white.opacity(0.6)) {
                    vm.setSelectedLightsOn(false)
                }

                divider

                actionButton(icon: "slider.horizontal.3", label: "Brightness", color: .white.opacity(0.75)) {
                    // Seed slider to average brightness of selected lights
                    let selected = vm.selectedLights
                    if !selected.isEmpty {
                        bulkBrightness = selected.map(\.brightness).reduce(0, +) / Double(selected.count)
                    }
                    showBrightnessSheet = true
                }

                divider

                actionButton(icon: "sparkles", label: "Scene", color: amber) {
                    onCreateScene()
                }
            }
            .padding(.bottom, 4)
        }
        .background {
            ZStack {
                // Frosted glass base
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                // Subtle amber tint
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(amber.opacity(0.06))
                // Amber top border
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [amber.opacity(0.45), amber.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: -4)
        }
        .padding(.horizontal, 16)
        // Brightness sheet
        .sheet(isPresented: $showBrightnessSheet) {
            brightnessSheet
                .presentationDetents([.fraction(0.32)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Brightness Sheet

    private var brightnessSheet: some View {
        VStack(spacing: 20) {
            Text("BRIGHTNESS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                Image(systemName: "sun.min.fill")
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.system(size: 14))

                Slider(value: $bulkBrightness, in: 1...100)
                    .tint(amber)

                Image(systemName: "sun.max.fill")
                    .foregroundStyle(amber)
                    .font(.system(size: 14))
            }

            Text("\(Int(bulkBrightness))%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(response: 0.25), value: Int(bulkBrightness))

            Button {
                vm.setSelectedLightsBrightness(bulkBrightness)
                showBrightnessSheet = false
            } label: {
                Text("Apply to \(vm.selectedLightIDs.count) light\(vm.selectedLightIDs.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.09, green: 0.08, blue: 0.14))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(amber)
                            .shadow(color: amber.opacity(0.45), radius: 10)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

    private func actionButton(
        icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 36)
    }
}
