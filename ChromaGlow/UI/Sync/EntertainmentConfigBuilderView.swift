// EntertainmentConfigBuilderView.swift
// ChromaGlow — Entertainment Area Creation UI
//
// Allows users to create entertainment configurations directly in-app
// without needing the official Hue app. Presented as a sheet from the
// Sync tab controls card.
//
// Flow:
//   1. Name your area
//   2. Select lights to include
//   3. (Optional) Arrange positions
//   4. POST to bridge → config created → auto-select for streaming

import SwiftUI

// MARK: - EntertainmentConfigBuilderView

struct EntertainmentConfigBuilderView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    /// Called when a new config is created — engine should reload configs.
    var onCreated: ((EntertainmentConfig) -> Void)?

    // MARK: State
    @State private var areaName = ""
    @State private var selectedLightIDs: Set<String> = []
    @State private var availableLights: [HueLight] = []
    @State private var isLoading = false
    @State private var isSaving  = false
    @State private var errorMessage: String?

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)
    private let maxLights = 10

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading lights…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    mainContent
                }
            }
            .navigationTitle("New Entertainment Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createConfig() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canCreate ? amber : .white.opacity(0.25))
                        .disabled(!canCreate || isSaving)
                }
            }
            .preferredColorScheme(.dark)
        }
        .task { await loadLights() }
    }

    private var canCreate: Bool {
        !areaName.trimmingCharacters(in: .whitespaces).isEmpty
        && !selectedLightIDs.isEmpty
        && selectedLightIDs.count <= maxLights
    }

    private var atLimit: Bool { selectedLightIDs.count >= maxLights }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {

                // ── Name ────────────────────────────────────
                nameSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                // ── Light Picker ────────────────────────────
                lightPickerSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── Info ────────────────────────────────────
                infoSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // ── Error ───────────────────────────────────
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }

                Color.clear.frame(height: 40)
            }
        }
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Area Name")

            TextField("e.g. Living Room Music", text: $areaName)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    areaName.isEmpty ? Color.white.opacity(0.08) : amber.opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                )
                .autocorrectionDisabled()
        }
    }

    // MARK: - Light Picker

    private var lightPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Select Lights")
                Spacer()
                Text("\(selectedLightIDs.count) / \(maxLights)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(atLimit ? amber : .white.opacity(0.45))
            }

            if atLimit {
                Text("Maximum of \(maxLights) lights per entertainment area")
                    .font(.system(size: 11))
                    .foregroundStyle(amber.opacity(0.6))
            }

            if availableLights.isEmpty {
                Text("No lights found on bridge")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.vertical, 20)
            } else {
                // Select All / Deselect All
                HStack(spacing: 10) {
                    let allSelected = Set(availableLights.map(\.id)) == selectedLightIDs
                    selectAllChip(allSelected: allSelected)
                    Spacer()
                }
                .padding(.bottom, 4)

                // Light grid
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(availableLights) { light in
                        lightCard(light)
                    }
                }
            }
        }
    }

    private func selectAllChip(allSelected: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.25)) {
                if allSelected {
                    selectedLightIDs.removeAll()
                } else {
                    // Cap at maxLights
                    selectedLightIDs = Set(availableLights.prefix(maxLights).map(\.id))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                Text(allSelected ? "Deselect All" : "Select All")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(allSelected ? amber : .white.opacity(0.5))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(allSelected ? amber.opacity(0.12) : .white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func lightCard(_ light: HueLight) -> some View {
        let isSelected = selectedLightIDs.contains(light.id)
        let isDisabled = !isSelected && atLimit
        return Button {
            withAnimation(.spring(response: 0.25)) {
                if isSelected {
                    selectedLightIDs.remove(light.id)
                } else if !atLimit {
                    selectedLightIDs.insert(light.id)
                }
            }
            HapticManager.shared.light()
        } label: {
            HStack(spacing: 10) {
                // Checkmark
                ZStack {
                    Circle()
                        .fill(isSelected ? amber : .white.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: isSelected ? "checkmark" : "lightbulb.fill")
                        .font(.system(size: isSelected ? 12 : 13, weight: .medium))
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.4))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(light.metadata.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(lightCapability(light))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? amber.opacity(0.10) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelected ? amber.opacity(0.45) : Color.white.opacity(0.07),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func lightCapability(_ light: HueLight) -> String {
        if light.color != nil { return "Color" }
        if light.color_temperature != nil { return "White Ambiance" }
        return "Dimmable"
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(amber.opacity(0.6))
                Text("Entertainment areas enable ultra-low-latency streaming for music sync. Lights in the area will be controlled directly via the bridge's Entertainment API.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(amber.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(amber.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(0.8)
    }

    // MARK: - Load Lights + Entertainment Services

    /// Maps light ID → entertainment service ID (same device, different service).
    @State private var lightToEntertainmentID: [String: String] = [:]

    private func loadLights() async {
        isLoading = true
        defer { isLoading = false }

        guard let client = orchestrator.primaryAPIClient else { return }
        do {
            let (ip, token) = try client.credentials()

            // Fetch lights and entertainment services in parallel
            async let lightsFetch = client.fetchLights()
            async let entData = client.get(
                path: "/clip/v2/resource/entertainment",
                ip: ip, token: token
            )

            let lights = try await lightsFetch
            let entertainmentData = try await entData

            // Parse entertainment services to build device → entertainment ID mapping
            // Entertainment service JSON: { id, owner: { rid: <device_id>, rtype: "device" } }
            var deviceToEntID: [String: String] = [:]
            if let json = try? JSONSerialization.jsonObject(with: entertainmentData) as? [String: Any],
               let items = json["data"] as? [[String: Any]] {
                for item in items {
                    guard let entID = item["id"] as? String,
                          let owner = item["owner"] as? [String: Any],
                          let deviceID = owner["rid"] as? String else { continue }
                    deviceToEntID[deviceID] = entID
                }
            }

            // Build light ID → entertainment ID mapping via shared device owner
            var mapping: [String: String] = [:]
            for light in lights {
                if let deviceID = light.owner?.rid,
                   let entID = deviceToEntID[deviceID] {
                    mapping[light.id] = entID
                }
            }
            lightToEntertainmentID = mapping

            // Only show lights that have entertainment capability
            let entertainmentCapableLights = lights.filter { mapping[$0.id] != nil }

            // Sort: color lights first, then by name
            availableLights = entertainmentCapableLights.sorted { a, b in
                let aColor = a.color != nil
                let bColor = b.color != nil
                if aColor != bColor { return aColor }
                return a.metadata.name < b.metadata.name
            }

            if availableLights.isEmpty && !lights.isEmpty {
                errorMessage = "No entertainment-capable lights found. Lights must support the Entertainment API (Color or Ambiance bulbs)."
            }
        } catch {
            errorMessage = "Failed to load lights: \(error.localizedDescription)"
        }
    }

    // MARK: - Create Entertainment Config

    private func createConfig() async {
        guard canCreate else { return }
        isSaving = true
        errorMessage = nil

        guard let client = orchestrator.primaryAPIClient else {
            errorMessage = "No bridge connection"
            isSaving = false
            return
        }

        do {
            let (ip, token) = try client.credentials()

            let selectedLights = availableLights.filter { selectedLightIDs.contains($0.id) }

            // Build service_locations — match exact format of working Hue app config:
            // requires BOTH position (object) + positions (array) + equalization_factor
            var serviceLocations: [[String: Any]] = []
            for (index, light) in selectedLights.enumerated() {
                guard let entID = lightToEntertainmentID[light.id] else { continue }

                let t = selectedLights.count > 1
                    ? Double(index) / Double(selectedLights.count - 1)
                    : 0.5
                let x = -1.0 + t * 2.0
                let pos: [String: Double] = ["x": x, "y": 0.0, "z": 0.0]

                serviceLocations.append([
                    "service": [
                        "rid": entID,
                        "rtype": "entertainment"
                    ],
                    "position": pos,
                    "positions": [pos],
                    "equalization_factor": 1.0
                ])
            }

            guard !serviceLocations.isEmpty else {
                errorMessage = "Selected lights don't support Entertainment API"
                isSaving = false
                return
            }

            let body: [String: Any] = [
                "metadata": ["name": areaName.trimmingCharacters(in: .whitespaces)],
                "configuration_type": "music",
                "locations": [
                    "service_locations": serviceLocations
                ]
            ]

            let data = try await client.post(
                path: "/clip/v2/resource/entertainment_configuration",
                body: body, ip: ip, token: token
            )

            // Parse the created config ID from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]],
               let first = dataArr.first,
               let rid = first["rid"] as? String {
                let config = EntertainmentConfig(
                    id: rid,
                    name: areaName.trimmingCharacters(in: .whitespaces),
                    channels: selectedLights.enumerated().map { (i, light) in
                        EntertainmentChannel(
                            id: i,
                            lightServiceIDs: [light.id],
                            position: (x: -1.0 + (selectedLights.count > 1 ? Double(i) / Double(selectedLights.count - 1) * 2.0 : 0.0), y: 0.0, z: 0.0)
                        )
                    }
                )
                onCreated?(config)
            }

            dismiss()
        } catch {
            errorMessage = "Failed to create: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
