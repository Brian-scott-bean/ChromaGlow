// BridgeManagerView.swift
// HueHome Pro — Stage 2A Multi-Bridge
//
// Settings sub-screen for managing all registered bridges.
// Shows each bridge with live status, device count, and CRUD controls.
// "Add Bridge" triggers a new BridgeSetupView pairing flow.

import SwiftUI
import SwiftData

struct BridgeManagerView: View {

    @Environment(\.modelContext)    private var modelContext
    @Environment(\.colorScheme)     private var colorScheme
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]

    @State private var showAddBridge     = false
    @State private var bridgeToDelete:   BridgeRecord? = nil
    @State private var showDeleteAlert   = false
    @State private var editingBridge:    BridgeRecord? = nil

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if bridges.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(bridges) { bridge in
                        BridgeRow(bridge: bridge, orchestrator: orchestrator)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    bridgeToDelete = bridge
                                    showDeleteAlert = true
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }

                                Button {
                                    editingBridge = bridge
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(HuePalette.amber)
                            }
                    }
                    .onMove(perform: reorder)

                    addBridgeButton
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Bridges")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .foregroundStyle(HuePalette.amber)
            }
        }
        .alert("Remove Bridge?", isPresented: $showDeleteAlert, presenting: bridgeToDelete) { bridge in
            Button("Remove", role: .destructive) { delete(bridge) }
            Button("Cancel", role: .cancel) {}
        } message: { bridge in
            Text("Remove bridge? Keychain credentials will be deleted. This cannot be undone.")
        }
        .sheet(isPresented: $showAddBridge) {
            NavigationStack {
                BridgeSetupView(
                    isAddingAdditional: true,
                    onBridgeAdded: { record in
                        showAddBridge = false
                        orchestrator.addBridge(record)
                        Task { await orchestrator.loadAll() }
                    }
                )
            }
        }
        .sheet(item: $editingBridge) { bridge in
            BridgeRenameSheet(bridge: bridge)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: HueSpacing.xl) {
            AmberRadialGlow(radius: 50)
                .overlay {
                    Image(systemName: "network.slash")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(HuePalette.amber)
                }
                .frame(width: 80, height: 80)

            VStack(spacing: HueSpacing.sm) {
                Text("No Bridges")
                    .font(HueFont.displaySmall)
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textPrimary : HuePalette.Estate.textPrimary)
                Text("Pair your first Hue Bridge to get started.")
                    .font(HueFont.body)
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textSecondary : HuePalette.Estate.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showAddBridge = true
            } label: {
                Label("Pair a Bridge", systemImage: "plus.circle.fill")
                    .font(HueFont.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, HueSpacing.xxl)
                    .padding(.vertical, HueSpacing.md)
                    .background(HuePalette.amber)
                    .clipShape(Capsule())
            }
        }
        .padding(HueSpacing.section)
    }

    // MARK: - Add Bridge Button

    private var addBridgeButton: some View {
        Button {
            showAddBridge = true
        } label: {
            HStack(spacing: HueSpacing.md) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(HuePalette.amber)
                Text("Add Another Bridge")
                    .font(HueFont.body.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textPrimary : HuePalette.Estate.textPrimary)
                Spacer()
            }
            .padding(HueSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: HueRadius.lg)
                    .fill(colorScheme == .dark
                      ? HuePalette.Noir.surface.opacity(0.6)
                      : HuePalette.Estate.surface.opacity(0.8))
                    .overlay {
                        RoundedRectangle(cornerRadius: HueRadius.lg)
                            .strokeBorder(
                                colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func delete(_ bridge: BridgeRecord) {
        orchestrator.removeBridge(id: bridge.id)
        modelContext.delete(bridge)
        try? modelContext.save()
    }

    private func reorder(from source: IndexSet, to destination: Int) {
        var sorted = bridges
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, bridge) in sorted.enumerated() {
            bridge.sortOrder = i
        }
        try? modelContext.save()
    }

    private var background: Color {
        colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background
    }
}

// MARK: - Bridge Row

private struct BridgeRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let bridge: BridgeRecord
    let orchestrator: UnifiedOrchestrator

    var statusColor: Color {
        switch orchestrator.connectionStatus[bridge.id] {
        case .connected:          return .green
        case .connecting:         return HuePalette.amber
        case .error:              return .red
        case .disabled, nil:      return .gray
        }
    }

    var statusLabel: String {
        switch orchestrator.connectionStatus[bridge.id] {
        case .connected:          return "Connected"
        case .connecting:         return "Connecting…"
        case .error(let msg):     return msg
        case .disabled, nil:      return "Disabled"
        }
    }

    var bridgeRooms: [RoomDisplayItem] {
        orchestrator.rooms(for: bridge.id)
    }

    var body: some View {
        HStack(spacing: HueSpacing.lg) {
            // Bridge icon with accent color
            let accentColor: Color = Color(hex: bridge.accentHex ?? "") ?? HuePalette.amber
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.name)
                    .font(HueFont.callout.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textPrimary : HuePalette.Estate.textPrimary)

                if let label = bridge.locationLabel {
                    Text(label)
                        .font(HueFont.caption)
                        .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textSecondary : HuePalette.Estate.textSecondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(HueFont.micro)
                        .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textTertiary : HuePalette.Estate.textTertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(bridgeRooms.count)")
                    .font(HueFont.callout.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textPrimary : HuePalette.Estate.textPrimary)
                Text("rooms")
                    .font(HueFont.micro)
                    .foregroundStyle(colorScheme == .dark ? HuePalette.Noir.textTertiary : HuePalette.Estate.textTertiary)
            }
        }
        .padding(HueSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: HueRadius.lg)
                .fill(colorScheme == .dark
                      ? HuePalette.Noir.surface.opacity(0.6)
                      : HuePalette.Estate.surface.opacity(0.8))
                .overlay {
                    RoundedRectangle(cornerRadius: HueRadius.lg)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                }
        }
    }
}

// MARK: - Bridge Rename Sheet

private struct BridgeRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    let bridge: BridgeRecord
    @State private var name: String = ""
    @State private var locationLabel: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge Name") {
                    TextField("e.g. Main Bridge", text: $name)
                }
                Section("Location (optional)") {
                    TextField("e.g. Living Area, Garage", text: $locationLabel)
                }
            }
            .navigationTitle("Edit Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        bridge.name = name
                        bridge.locationLabel = locationLabel.isEmpty ? nil : locationLabel
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(HuePalette.amber)
                }
            }
        }
        .onAppear {
            name = bridge.name
            locationLabel = bridge.locationLabel ?? ""
        }
    }
}
