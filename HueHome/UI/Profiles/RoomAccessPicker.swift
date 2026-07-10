// RoomAccessPicker.swift
// ChromaGlow — Family Sharing Phase 3 (per-profile room selection)
//
// Rooms and zones grouped by bridge, from the OWNER's (unfiltered)
// orchestrator lists. Selection is a flat list of v2 group UUIDs — the
// mint flow intersects it per bridge, and the guest-side policy enforces
// it. Stale ids (a selected room that no longer exists) surface in their
// own section instead of silently riding along forever.

import SwiftUI
import SwiftData

struct RoomAccessPicker: View {

    @Binding var selection: [String]

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]

    var body: some View {
        List {
            if liveGroups.isEmpty {
                Section {
                    Text("No rooms loaded yet. Open the dashboard once so this phone has the bridge's room list, then come back.")
                        .font(HueFont.stageStatus)
                        .foregroundStyle(StagePalette.muted)
                        .listRowBackground(Color.white.opacity(0.04))
                }
            }

            ForEach(bridgeSections, id: \.bridgeID) { section in
                Section {
                    ForEach(section.groups) { group in
                        groupRow(group)
                    }
                } header: {
                    HStack {
                        Text(section.name.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button(allSelected(section) ? "None" : "All") {
                            toggleAll(section)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HuePalette.amber)
                    }
                }
            }

            if !staleSelectedIDs.isEmpty {
                Section {
                    ForEach(staleSelectedIDs, id: \.self) { staleID in
                        HStack {
                            Text("Unknown room")
                                .font(HueFont.stageControl)
                                .foregroundStyle(StagePalette.muted)
                            Spacer()
                            Button("Remove") {
                                selection.removeAll { $0 == staleID }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                } header: {
                    Text("NO LONGER FOUND")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.orange.opacity(0.7))
                } footer: {
                    Text("These were selected before but no bridge reports them anymore (deleted room, removed bridge).")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(colors: [Color(hex: "#141224"), Color(hex: "#0B0A14")],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        .navigationTitle("Rooms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(selection.count) selected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HuePalette.amber)
            }
        }
        .preferredColorScheme(.dark)
    }

    // ──────────────────────────────────────────────
    // MARK: - Sections
    // ──────────────────────────────────────────────

    private struct BridgeSection {
        let bridgeID: String
        let name: String
        let groups: [RoomDisplayItem]
    }

    private var liveGroups: [RoomDisplayItem] {
        orchestrator.allRooms + orchestrator.allZones
    }

    private var bridgeSections: [BridgeSection] {
        let byBridge = Dictionary(grouping: liveGroups, by: { $0.bridgeID ?? "legacy" })
        // Bridge order follows the user's sortOrder; unknown ids trail.
        let ordered = bridges.map(\.id).filter { byBridge.keys.contains($0) }
            + byBridge.keys.filter { key in !bridges.contains(where: { $0.id == key }) }.sorted()
        return ordered.compactMap { bridgeID in
            guard let groups = byBridge[bridgeID] else { return nil }
            let name = bridges.first { $0.id == bridgeID }?.name
                ?? (bridgeID == "legacy" ? "Bridge" : "Bridge \(bridgeID.prefix(4))")
            // Rooms first, then zones, alphabetical inside each.
            let sorted = groups.sorted {
                if $0.kind != $1.kind { return $0.kind == .room }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
            return BridgeSection(bridgeID: bridgeID, name: name, groups: sorted)
        }
    }

    private var staleSelectedIDs: [String] {
        let live = Set(liveGroups.map(\.id))
        return selection.filter { !live.contains($0) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Rows / actions
    // ──────────────────────────────────────────────

    private func groupRow(_ group: RoomDisplayItem) -> some View {
        let isSelected = selection.contains(group.id)
        return Button {
            if isSelected {
                selection.removeAll { $0 == group.id }
            } else {
                selection.append(group.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: group.kind == .zone ? "square.3.layers.3d" : "lamp.ceiling.inverse")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? HuePalette.amber : StagePalette.muted)
                    .frame(width: 22)
                Text(group.kind == .zone ? "\(group.name) (Zone)" : group.name)
                    .font(HueFont.stageControl)
                    .foregroundStyle(StagePalette.ink)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? HuePalette.amber : .white.opacity(0.2))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.04))
    }

    private func allSelected(_ section: BridgeSection) -> Bool {
        section.groups.allSatisfy { selection.contains($0.id) }
    }

    private func toggleAll(_ section: BridgeSection) {
        if allSelected(section) {
            let ids = Set(section.groups.map(\.id))
            selection.removeAll { ids.contains($0) }
        } else {
            let existing = Set(selection)
            selection.append(contentsOf: section.groups.map(\.id).filter { !existing.contains($0) })
        }
    }
}
