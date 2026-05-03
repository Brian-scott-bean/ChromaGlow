// DevicesView.swift
// HueHome Pro — Devices Tab
//
// Shows all paired Hue devices across all bridges, grouped by type.
// Displays model, firmware version, and device category at a glance.

import SwiftUI

// MARK: - DevicesView

struct DevicesView: View {

    @State private var vm = DevicesViewModel()
    @State private var showLog = false
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    private let amber  = Color(red: 1.0, green: 0.76, blue: 0.20)
    private let teal   = Color(red: 0.25, green: 0.85, blue: 0.75)
    private let blue   = Color(red: 0.40, green: 0.65, blue: 1.00)
    private let purple = Color(red: 0.55, green: 0.35, blue: 1.00)

    var body: some View {
        ZStack {
            ambientBackground

            Group {
                if vm.isLoading && vm.devices.isEmpty {
                    loadingView
                } else if let error = vm.errorMessage, vm.devices.isEmpty {
                    errorView(error)
                } else if vm.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .task {
            vm.configure(bridgeIDs: orchestrator.allBridgeIDs, orchestrator: orchestrator)
            await vm.loadDevices()
        }
        .refreshable { await vm.loadDevices() }
        .preferredColorScheme(.dark)
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(colors: [teal.opacity(0.15), .clear],
                                     center: .center, startRadius: 0, endRadius: 200))
                .frame(width: 320)
                .offset(x: -110, y: -160)
                .blur(radius: 24)
            Circle()
                .fill(RadialGradient(colors: [amber.opacity(0.10), .clear],
                                     center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 260)
                .offset(x: 120, y: 180)
                .blur(radius: 24)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Device List
    // ──────────────────────────────────────────────

    private var deviceList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                let groups = vm.grouped()
                VStack(spacing: 24) {
                    ForEach(groups, id: \.0.rawValue) { (type, items) in
                        deviceGroup(type: type, items: items)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
    }

    // ── Summary Header ────────────────────────────

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.devices.count) paired device\(vm.devices.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                let lightCount = vm.devices.filter { $0.deviceType == .light }.count
                Text("\(lightCount) light\(lightCount == 1 ? "" : "s") · \(vm.devices.count - lightCount) other")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14))
                .foregroundStyle(teal.opacity(0.8))
        }
    }

    // ── Group Section ─────────────────────────────

    private func deviceGroup(
        type: DeviceDisplayItem.DeviceType,
        items: [DeviceDisplayItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: type.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color(for: type))
                Text(type.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text("(\(items.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
            }

            GlassmorphicCard(isActive: true, glowColor: color(for: type)) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, device in
                        DeviceRow(device: device, accentColor: color(for: type))
                        if idx < items.count - 1 {
                            Divider().background(Color.white.opacity(0.07))
                        }
                    }
                }
            }
        }
    }

    // ── Empty State ───────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text("No devices found")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("Make sure your Bridge is connected and you're on the same network.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showLog.toggle() } label: {
                Image(systemName: "terminal").foregroundStyle(.white.opacity(0.7))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.isLoading {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(0.8)
            } else {
                Button { Task { await vm.loadDevices() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Loading / Error
    // ──────────────────────────────────────────────

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().progressViewStyle(.circular).tint(teal).scaleEffect(1.6)
            Text("Loading devices…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadDevices() } }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Log Sheet
    // ──────────────────────────────────────────────

    private var logSheet: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Devices Console")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func color(for type: DeviceDisplayItem.DeviceType) -> Color {
        switch type.colorKey {
        case "amber":  return amber
        case "blue":   return blue
        case "teal":   return teal
        case "purple": return purple
        default:       return .white.opacity(0.6)
        }
    }
}

// MARK: - DeviceRow

struct DeviceRow: View {

    let device:      DeviceDisplayItem
    let accentColor: Color

    var body: some View {
        HStack(spacing: 14) {
            // Type icon
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: device.deviceType.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            // Name + model
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let model = device.modelID {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                } else if let product = device.productName {
                    Text(product)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Spacer()

            // Firmware version badge
            if let fw = device.firmwareShort {
                Text(fw)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.07))
                    )
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
