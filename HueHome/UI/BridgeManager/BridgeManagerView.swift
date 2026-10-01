// BridgeManagerView.swift
// ChromaGlow — Bridges (Luminous).
//
// Every registered bridge with its live connection, rooms and accent; add,
// rename, reorder, remove. Stays a List so swipe-to-delete, Edit and drag
// reordering keep working — each row is a glass card over the dark room.
// "Add Another Bridge" opens the same pairing flow as first launch.

import SwiftUI
import SwiftData

struct BridgeManagerView: View {

    @Environment(\.modelContext)    private var modelContext
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]

    @State private var showAddBridge     = false
    @State private var bridgeToDelete:   BridgeRecord? = nil
    @State private var showDeleteAlert   = false
    @State private var editingBridge:    BridgeRecord? = nil

    private static let rowInsets = EdgeInsets(top: 5, leading: HueSpacing.screenH, bottom: 5, trailing: HueSpacing.screenH)

    var body: some View {
        List {
            LuminousScreenTitle(title: "Bridges",
                                eyebrow: "System",
                                eyebrowSymbol: "network",
                                eyebrowTint: LuminousPalette.cyan,
                                subtitle: bridges.isEmpty
                                    ? "Pair a bridge and every room it knows appears on Home."
                                    : "Hold a bridge to rename or remove it. Edit to reorder.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: HueSpacing.screenH, bottom: 12, trailing: HueSpacing.screenH))

            if bridges.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)
            } else {
                ForEach(bridges) { bridge in
                    BridgeRow(bridge: bridge, orchestrator: orchestrator)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets)
                        .contextMenu {
                            // Long-press context menu: backup delete path
                            Button(role: .destructive) {
                                bridgeToDelete = bridge
                                showDeleteAlert = true
                            } label: {
                                Label("Remove Bridge", systemImage: "trash")
                            }
                            Button {
                                editingBridge = bridge
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                }
                .onDelete { indexSet in
                    // Standard iOS swipe-to-delete — fires before custom alert
                    if let idx = indexSet.first {
                        bridgeToDelete = bridges[idx]
                        showDeleteAlert = true
                    }
                }
                .onMove(perform: reorder)

                addBridgeButton
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet], intensity: 0.6) }
        .luminousPageChrome(title: "Bridges")
        .toolbar {
            if !bridges.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                        .foregroundStyle(LuminousPalette.cyan)
                }
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
        LuminousEmptyState(symbol: "network.slash",
                           title: "No Bridges",
                           message: "Pair your first Hue Bridge to get started.",
                           actionTitle: "Pair a Bridge",
                           action: { showAddBridge = true })
    }

    // MARK: - Add Bridge Button

    private var addBridgeButton: some View {
        Button {
            showAddBridge = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(LuminousPalette.void)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LuminousPalette.signalGradient))
                    .shadow(color: LuminousPalette.cyan.opacity(0.5), radius: 8)
                Text("Add Another Bridge")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .luminousGlass(radius: LuminousPalette.cardRadius, accent: LuminousPalette.cyan, selected: true)
            .contentShape(RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle())
    }

    // MARK: - Actions

    private func delete(_ bridge: BridgeRecord) {
        // Async: removeBridge now stops the bridge's running effects first.
        Task { await orchestrator.removeBridge(id: bridge.id) }
        modelContext.delete(bridge)
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[BridgeManagerView] modelContext.save() failed: \(error)")
            #endif
        }
        // Family Sharing: prune any guest grant that referenced this bridge
        // so the shell (banner, tab gating) reflects reality immediately.
        orchestrator.updateGuestGrants(from: modelContext)
    }

    private func reorder(from source: IndexSet, to destination: Int) {
        var sorted = bridges
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, bridge) in sorted.enumerated() {
            bridge.sortOrder = i
        }
        try? modelContext.save()
    }
}

// MARK: - Bridge Row

/// One bridge: its accent glowing in a badge, its name and place, its live
/// connection, and how many rooms it carries.
private struct BridgeRow: View {
    let bridge: BridgeRecord
    let orchestrator: UnifiedOrchestrator

    private var status: BridgeConnectionStatus? { orchestrator.connectionStatus[bridge.id] }

    var statusColor: Color {
        status?.luminousTint ?? LuminousPalette.inkSecondary
    }

    var statusLabel: String {
        switch status {
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
        let accentColor: Color = bridge.accentHex.map { Color(hex: $0) } ?? LuminousPalette.cyan
        return HStack(spacing: 14) {
            LuminousIconBadge(symbol: "network", tint: accentColor, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.name)
                    .font(LuminousType.cardTitle)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                if let label = bridge.locationLabel {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusColor, radius: 3)
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(bridgeRooms.count)")
                    .font(LuminousType.bigValue)
                    .foregroundStyle(LuminousPalette.ink)
                Text(bridgeRooms.count == 1 ? "room" : "rooms")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
        }
        .padding(16)
        .luminousPanel(radius: LuminousPalette.cardRadius, glow: accentColor, glowStrength: status.map { if case .connected = $0 { return 0.6 } else { return 0.2 } } ?? 0.2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bridge Rename Sheet

private struct BridgeRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let bridge: BridgeRecord
    @State private var name: String = ""
    @State private var locationLabel: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LuminousScreenTitle(title: "Edit Bridge", eyebrow: "Bridges", eyebrowSymbol: "network",
                                        eyebrowTint: LuminousPalette.cyan)
                    LuminousTextField(caption: "Bridge Name", placeholder: "e.g. Main Bridge", text: $name)
                    LuminousTextField(caption: "Location (optional)", placeholder: "e.g. Living Area, Garage",
                                      text: $locationLabel)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
            }
            .background { LuminousAmbience(colors: [LuminousPalette.cyan], intensity: 0.6) }
            .navigationTitle("Edit Bridge")
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
                    Button("Save") {
                        bridge.name = name
                        bridge.locationLabel = locationLabel.isEmpty ? nil : locationLabel
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .luminousSheet()
        .presentationDetents([.medium, .large])
        .onAppear {
            name = bridge.name
            locationLabel = bridge.locationLabel ?? ""
        }
    }
}
