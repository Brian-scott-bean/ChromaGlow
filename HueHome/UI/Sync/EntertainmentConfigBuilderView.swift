// EntertainmentConfigBuilderView.swift
// CastChroma — Entertainment Area Creation UI
//
// Allows users to create entertainment configurations directly in-app
// without needing the official Hue app. Presented as a sheet from More →
// Entertainment Areas (and the Composer v1 layer sheet in Studio Classic).
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
    /// M-18: the bridge this area is built on. Auto-selected for single-bridge
    /// homes; a picker appears when several bridges are registered so the
    /// config is enumerated from — and POSTed to — the intended bridge.
    @State private var selectedBridgeID: String?

    /// Family Sharing: a new area is POSTed to the bridge itself, so granted
    /// (guest) bridges are never offered — only bridges this phone owns.
    private var ownedBridgeIDs: [String] {
        orchestrator.allBridgeIDs.filter { !orchestrator.isGuestGrantedBridge($0) }.sorted()
    }

    /// The selected bridge's client — nil when nothing owned is selected.
    /// Never falls through `hueClient(for: nil)`, whose single-bridge
    /// fallback would hand back a granted bridge's client.
    private var selectedOwnedClient: HueAPIClient? {
        guard let selectedBridgeID, !orchestrator.isGuestGrantedBridge(selectedBridgeID) else {
            return nil
        }
        return orchestrator.hueClient(for: selectedBridgeID)
    }

    private let maxLights = 10

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 14) {
                        ProgressView().tint(LuminousPalette.cyan).scaleEffect(1.3)
                        Text("Loading lights…")
                            .font(.subheadline)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mainContent
                }
            }
            .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet], intensity: 0.65) }
            .navigationTitle("New Entertainment Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createConfig() } }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canCreate ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
                        .disabled(!canCreate || isSaving)
                }
            }
        }
        .luminousSheet()
        .task {
            if selectedBridgeID == nil {
                selectedBridgeID = ownedBridgeIDs.first
            }
            await loadLights()
        }
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
            VStack(alignment: .leading, spacing: 20) {
                LuminousScreenTitle(title: "New area",
                                    eyebrow: "Entertainment Areas",
                                    eyebrowSymbol: "dot.radiowaves.left.and.right",
                                    eyebrowTint: LuminousPalette.cyan,
                                    subtitle: "Name it, pick up to \(maxLights) lights, and the bridge does the rest.")

                // ── Bridge (multi-bridge homes only) ────────
                if ownedBridgeIDs.count > 1 {
                    bridgePickerSection
                }

                LuminousTextField(caption: "Area Name", placeholder: "e.g. Living Room Music", text: $areaName)
                    .autocorrectionDisabled()

                lightPickerSection

                LuminousNotice(text: "Entertainment areas let lights respond instantly for music sync. Lights in the area are controlled directly by your Hue Bridge.",
                               symbol: "info.circle.fill", tint: LuminousPalette.cyan)

                if let error = errorMessage {
                    LuminousNotice(text: error, symbol: "exclamationmark.triangle.fill", tint: LuminousPalette.danger)
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Bridge Picker (M-18)

    private var bridgePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: "Bridge").padding(.horizontal, 6)
            Menu {
                ForEach(ownedBridgeIDs, id: \.self) { bridgeID in
                    Button {
                        guard bridgeID != selectedBridgeID else { return }
                        selectedBridgeID = bridgeID
                        selectedLightIDs = []
                        availableLights  = []
                        errorMessage     = nil
                        Task { await loadLights() }
                    } label: {
                        if bridgeID == selectedBridgeID {
                            Label(orchestrator.bridgeName(for: bridgeID) ?? "Bridge", systemImage: "checkmark")
                        } else {
                            Text(orchestrator.bridgeName(for: bridgeID) ?? "Bridge")
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LuminousPalette.cyan)
                    Text(selectedBridgeID.flatMap { orchestrator.bridgeName(for: $0) } ?? "Select a bridge")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .luminousGlass(radius: 16)
            }
        }
    }

    // MARK: - Light Picker

    private var lightPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LuminousEyebrow(text: "Select Lights")
                Spacer()
                Text("\(selectedLightIDs.count) / \(maxLights)")
                    .font(LuminousType.value)
                    .foregroundStyle(atLimit ? LuminousPalette.amber : LuminousPalette.inkSecondary)
            }
            .padding(.horizontal, 6)

            if atLimit {
                Text("Maximum of \(maxLights) lights per entertainment area")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LuminousPalette.amber)
                    .padding(.horizontal, 6)
            }

            if availableLights.isEmpty {
                Text("No lights found on bridge")
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .luminousGlass()
            } else {
                let allSelected = Set(availableLights.map(\.id)) == selectedLightIDs
                LuminousChip(title: allSelected ? "Deselect All" : "Select All",
                             symbol: allSelected ? "checkmark.circle.fill" : "circle",
                             selected: allSelected) {
                    withAnimation(.spring(response: 0.25)) {
                        if allSelected {
                            selectedLightIDs.removeAll()
                        } else {
                            // Cap at maxLights
                            selectedLightIDs = Set(availableLights.prefix(maxLights).map(\.id))
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(availableLights) { light in
                        lightCard(light)
                    }
                }
            }
        }
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
                Image(systemName: isSelected ? "checkmark" : "lightbulb.fill")
                    .font(.system(size: isSelected ? 13 : 13, weight: .bold))
                    .foregroundStyle(isSelected ? LuminousPalette.void : LuminousPalette.inkSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isSelected ? AnyShapeStyle(LuminousPalette.signalGradient)
                                                         : AnyShapeStyle(Color.white.opacity(0.08))))
                    .shadow(color: isSelected ? LuminousPalette.cyan.opacity(0.5) : .clear, radius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(light.metadata.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                    Text(lightCapability(light))
                        .font(.caption2)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .luminousGlass(radius: 16, accent: LuminousPalette.cyan, selected: isSelected)
            .opacity(isDisabled ? 0.4 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle(scale: 0.96))
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private func lightCapability(_ light: HueLight) -> String {
        if light.color != nil { return "Color" }
        if light.color_temperature != nil { return "White Ambiance" }
        return "Dimmable"
    }

    // MARK: - Load Lights + Entertainment Services

    /// Maps light ID → entertainment service ID (same device, different service).
    @State private var lightToEntertainmentID: [String: String] = [:]

    private func loadLights() async {
        isLoading = true
        defer { isLoading = false }

        // M-18: enumerate lights from the selected bridge, not the first one.
        guard let client = selectedOwnedClient else { return }
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

        // M-18: POST the new entertainment_configuration to the SAME bridge
        // the lights were enumerated from.
        guard let client = selectedOwnedClient else {
            errorMessage = "No bridge connection"
            isSaving = false
            return
        }

        do {
            let (ip, token) = try client.credentials()

            let selectedLights = availableLights.filter { selectedLightIDs.contains($0.id) }

            // Build service_locations — match exact format of working Hue app config:
            // requires BOTH position (object) + positions (array) + equalization_factor.
            // Round 3 (F): gradient-capable lights get TWO positions (a start
            // and an end) — that is what makes the bridge segment the strip
            // into multiple entertainment channels instead of one.
            var serviceLocations: [[String: Any]] = []
            for (index, light) in selectedLights.enumerated() {
                guard let entID = lightToEntertainmentID[light.id] else { continue }

                let t = selectedLights.count > 1
                    ? Double(index) / Double(selectedLights.count - 1)
                    : 0.5
                let x = -1.0 + t * 2.0
                let pos: [String: Double] = ["x": x, "y": 0.0, "z": 0.0]

                let isGradientStrip = (light.gradient?.points_capable ?? 0) >= 2
                let positions: [[String: Double]]
                if isGradientStrip {
                    // Span the strip across its slot (clamped to the ±1 room cube).
                    let halfSpan = 0.3
                    positions = [
                        ["x": max(-1.0, x - halfSpan), "y": 0.0, "z": 0.0],
                        ["x": min(1.0, x + halfSpan),  "y": 0.0, "z": 0.0],
                    ]
                } else {
                    positions = [pos]
                }

                serviceLocations.append([
                    "service": [
                        "rid": entID,
                        "rtype": "entertainment"
                    ],
                    "position": pos,
                    "positions": positions,
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
                // Round 3 (F): refetch the REAL config from the bridge — it
                // assigns the actual channel ids/positions (and segments
                // gradient strips into several channels). Fabricating them
                // locally desynced channel counts from what DTLS streams to.
                let real = (try? await EntertainmentConfigManager()
                    .fetchConfigs(client: client))?
                    .first(where: { $0.id == rid })
                let config = real ?? EntertainmentConfig(
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
