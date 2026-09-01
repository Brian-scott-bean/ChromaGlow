// RoomPickerSheetView.swift
// CastChroma — Slice 2 active-session manager + searchable room picker
// (spec §14.2 / §15.3).
//
// ACTIVE targets first: each row names the room/zone, its running look, and
// a tiny live indicator, and carries a one-tap Stop for THAT exact target —
// no need to navigate to its console first. A stopped target leaves the
// active section immediately and rejoins the searchable Rooms/Zones lists.
// Selecting an active row is an instant switch to that room's real live
// console. This sheet is room/session NAVIGATION, not customization — the
// customization surface itself stays the host's one scroll (Guard 13).

import SwiftUI

struct RoomPickerSheetView: View {

    let rooms: [RoomDisplayItem]
    let zones: [RoomDisplayItem]
    let selectedRoom: RoomDisplayItem?
    let runningEffects: [StudioSelectionKey: RunningEffect]  // exact bridge+group+kind key
    let onSelect: (RoomDisplayItem) -> Void
    /// One-tap stop for an ACTIVE row — exact key, never a sibling. Optional
    /// so read-only presentations keep working.
    var onStopActive: ((StudioSelectionKey) -> Void)? = nil

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    /// Active targets, stable-ordered (bridge, kind, name) — rooms the
    /// session is playing come FIRST, before any search list.
    private var activeEntries: [(key: StudioSelectionKey, effect: RunningEffect)] {
        runningEffects
            .map { (key: $0.key, effect: $0.value) }
            .sorted {
                ($0.effect.room.name, $0.key.bridgeID ?? "", $0.key.kind.rawValue)
                    < ($1.effect.room.name, $1.key.bridgeID ?? "", $1.key.kind.rawValue)
            }
    }

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
                // ── Active session, FIRST (spec §14.2) ────────
                if !activeEntries.isEmpty && searchText.isEmpty {
                    Section {
                        ForEach(activeEntries, id: \.key) { entry in
                            activeRow(entry.key, effect: entry.effect)
                        }
                    } header: {
                        Text("PLAYING NOW")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HuePalette.amber.opacity(0.8))
                            .tracking(0.8)
                    }
                }

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

    // ── Active row: room + running look + live dot + exact Stop ────

    private func activeRow(_ key: StudioSelectionKey, effect: RunningEffect) -> some View {
        let isSelected = selectedRoom.map { StudioSelectionKey(room: $0) } == key
        return HStack(spacing: 12) {
            Button {
                onSelect(effect.room)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(HuePalette.Noir.success)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(effect.room.name)
                            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.white)
                        Text(effect.card.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(effect.card.accentColor.opacity(0.85))
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HuePalette.amber)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(effect.room.name), playing \(effect.card.name)")
            .accessibilityHint("Switches to this room's live controls")

            if let onStopActive {
                Button {
                    onStopActive(key)
                    HapticManager.shared.medium()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(HuePalette.Noir.destructive)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(HuePalette.Noir.destructive.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(effect.card.name) in \(effect.room.name)")
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            isSelected ? HuePalette.amber.opacity(0.08) : Color.clear
        )
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
                if let effect = runningEffects[StudioSelectionKey(room: item)] {
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
