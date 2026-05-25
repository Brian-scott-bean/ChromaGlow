// RoomPickerSheetView.swift
// ChromaGlow — v0.16.0 Studio Room Picker
//
// Searchable half-sheet for selecting a room or zone.
// Grouped by type (Rooms / Zones) with section headers.
// Used by StudioView's swipeable nav title tap action.

import SwiftUI

struct RoomPickerSheetView: View {

    let rooms: [RoomDisplayItem]
    let zones: [RoomDisplayItem]
    let selectedRoom: RoomDisplayItem?
    let runningEffects: [String: RunningEffect]  // keyed by room ID
    let onSelect: (RoomDisplayItem) -> Void

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredRooms: [RoomDisplayItem] {
        if searchText.isEmpty { return rooms }
        return rooms.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredZones: [RoomDisplayItem] {
        if searchText.isEmpty { return zones }
        return zones.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Rooms section ─────────────────────────────
                if !filteredRooms.isEmpty {
                    Section {
                        ForEach(filteredRooms, id: \.id) { room in
                            roomRow(room, isZone: false)
                        }
                    } header: {
                        Text("ROOMS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(0.8)
                    }
                }

                // ── Zones section ─────────────────────────────
                if !filteredZones.isEmpty {
                    Section {
                        ForEach(filteredZones, id: \.id) { zone in
                            roomRow(zone, isZone: true)
                        }
                    } header: {
                        Text("ZONES")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(0.8)
                    }
                }

                // ── Empty state ───────────────────────────────
                if filteredRooms.isEmpty && filteredZones.isEmpty {
                    ContentUnavailableView(
                        "No results",
                        systemImage: "magnifyingglass",
                        description: Text("No rooms match \"\(searchText)\"")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Select Room")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search rooms…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HuePalette.amber)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // ── Row builder ───────────────────────────────────────

    private func roomRow(_ item: RoomDisplayItem, isZone: Bool) -> some View {
        let isSelected = selectedRoom?.id == item.id

        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                // Room/zone icon
                Image(systemName: isZone ? "square.3.layers.3d" : archetypeIcon(for: item.archetype))
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? HuePalette.amber : .white.opacity(0.5))
                    .frame(width: 24, height: 24)

                // Name
                Text(item.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.75))

                // Light count
                Text("\(item.lightCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.06)))

                Spacer()

                // Selected checkmark
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HuePalette.amber)
                }

                // Running effect indicator
                if let effect = runningEffects[item.id] {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(effect.card.accentColor)
                            .frame(width: 6, height: 6)
                        Text(effect.card.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(effect.card.accentColor.opacity(0.8))
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
            ? HuePalette.amber.opacity(0.08)
            : Color.clear
        )
    }
}
