// DevicesView.swift
// ChromaGlow — Devices & Updates (Luminous).
//
// Every paired device across every bridge, grouped by what it is — lights,
// controls, sensors, the bridge itself — with its model and firmware at a
// glance. Read-only by design. Pushed from More.

import SwiftUI

// MARK: - DevicesView

struct DevicesView: View {

    @State private var vm = DevicesViewModel()
    @State private var showLog = false
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    private let teal = Color(hex: "#40D9BF")

    var body: some View {
        Group {
            if vm.isLoading && vm.devices.isEmpty {
                loadingView
            } else if let error = vm.errorMessage, vm.devices.isEmpty {
                messagePage(LuminousEmptyState(symbol: "exclamationmark.triangle.fill",
                                               title: "Couldn't read your devices",
                                               message: error,
                                               actionTitle: "Try again",
                                               action: { Task { await vm.loadDevices() } }))
            } else if vm.devices.isEmpty {
                messagePage(LuminousEmptyState(symbol: "sensor.fill",
                                               title: "No devices found",
                                               message: "Make sure your Bridge is connected and you're on the same network."))
            } else {
                deviceList
            }
        }
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .task {
            vm.configure(bridgeIDs: orchestrator.allBridgeIDs, orchestrator: orchestrator)
            await vm.loadDevices()
        }
        .refreshable { await vm.loadDevices() }
    }

    // MARK: - List

    private var deviceList: some View {
        let lightCount = vm.devices.filter { $0.deviceType == .light }.count
        return LuminousPage(title: "Devices",
                            eyebrow: "Devices & Updates",
                            eyebrowSymbol: "sensor.fill",
                            tint: teal,
                            subtitle: "Everything paired with your bridges, with its model and firmware.",
                            ambience: [teal, LuminousPalette.cyan]) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LuminousStateChip(text: "\(vm.devices.count) paired device\(vm.devices.count == 1 ? "" : "s")",
                                      dot: teal, glowing: true)
                    LuminousStateChip(text: "\(lightCount) light\(lightCount == 1 ? "" : "s") · \(vm.devices.count - lightCount) other",
                                      dot: LuminousPalette.inkSecondary)
                }
            }
            .scrollClipDisabled()
            ForEach(vm.grouped(), id: \.0.rawValue) { (type, items) in
                LuminousGroup(title: "\(type.rawValue) · \(items.count)") {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, device in
                        DeviceRow(device: device, accentColor: color(for: type))
                        if idx < items.count - 1 { LuminousRowDivider() }
                    }
                }
            }
        }
    }

    private func messagePage(_ state: LuminousEmptyState) -> some View {
        LuminousPage(title: "Devices", eyebrow: "Devices & Updates", eyebrowSymbol: "sensor.fill",
                     tint: teal, ambience: [teal]) {
            state
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showLog.toggle() } label: {
                Image(systemName: "terminal").foregroundStyle(LuminousPalette.ink.opacity(0.75))
            }
            .accessibilityLabel("Devices console")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.isLoading {
                ProgressView().progressViewStyle(.circular).tint(LuminousPalette.ink).scaleEffect(0.8)
            } else {
                Button { Task { await vm.loadDevices() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                .accessibilityLabel("Refresh")
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView().progressViewStyle(.circular).tint(teal).scaleEffect(1.4)
            Text("Reading your devices…")
                .font(.subheadline)
                .foregroundStyle(LuminousPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LuminousAmbience(colors: [teal], intensity: 0.6) }
        .luminousPageChrome(title: "Devices")
    }

    // MARK: - Log Sheet

    private var logSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LuminousPalette.ink.opacity(0.8))
                                .id(idx)
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(LuminousPalette.void)
            .navigationTitle("Devices Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .luminousSheet()
    }

    // MARK: - Helpers

    private func color(for type: DeviceDisplayItem.DeviceType) -> Color {
        switch type.colorKey {
        case "amber":  return Color(hex: "#FFD36B")
        case "blue":   return Color(hex: "#6699FF")
        case "teal":   return teal
        case "purple": return LuminousPalette.violet
        default:       return LuminousPalette.inkSecondary
        }
    }
}

// MARK: - DeviceRow

/// One device: its glowing type icon, name, model and firmware. Self-padded
/// like `LuminousRow`, for a `LuminousGroup`.
struct DeviceRow: View {

    let device:      DeviceDisplayItem
    let accentColor: Color

    var body: some View {
        HStack(spacing: 14) {
            LuminousIconBadge(symbol: device.deviceType.icon, tint: accentColor, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                if let model = device.modelID {
                    Text(model)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                } else if let product = device.productName {
                    Text(product)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
            }

            Spacer(minLength: 0)

            if let fw = device.firmwareShort {
                Text(fw)
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(LuminousPalette.ink.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .accessibilityLabel("Firmware \(fw)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
