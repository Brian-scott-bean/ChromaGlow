// EditRoomSheet.swift
// CastChroma — Room & Zone CRUD
//
// Sheet for renaming a room/zone and picking a new archetype icon.
// Presented via .sheet in DashboardView when the user taps Edit Room/Zone
// from the action sheet triggered by the ··· button on a room card.

import SwiftUI

// MARK: - Archetype Option

private struct ArchetypeOption: Identifiable {
    let id:    String   // Hue V2 archetype string
    let label: String
    let icon:  String   // SF Symbol

    static let traditional: [ArchetypeOption] = [
        .init(id: "living_room",  label: "Living room",  icon: "sofa.fill"),
        .init(id: "kitchen",      label: "Kitchen",      icon: "fork.knife"),
        .init(id: "dining",       label: "Dining",       icon: "fork.knife.circle.fill"),
        .init(id: "bedroom",      label: "Bedroom",      icon: "bed.double.fill"),
        .init(id: "kids_bedroom", label: "Kids' room",   icon: "teddybear.fill"),
        .init(id: "bathroom",     label: "Bathroom",     icon: "shower.fill"),
        .init(id: "nursery",      label: "Nursery",      icon: "figure.and.child.holdinghands"),
        .init(id: "office",       label: "Office",       icon: "desktopcomputer"),
        .init(id: "gym",          label: "Gym",          icon: "dumbbell.fill"),
        .init(id: "recreation",   label: "Recreation",   icon: "gamecontroller.fill"),
        .init(id: "lounge",       label: "Lounge",       icon: "chair.fill"),
        .init(id: "guest_room",   label: "Guest room",   icon: "person.2.fill"),
        .init(id: "man_cave",     label: "Man cave",     icon: "popcorn.fill"),
        .init(id: "studio",       label: "Studio",       icon: "music.mike"),
        .init(id: "computer",     label: "Computer",     icon: "laptopcomputer"),
        .init(id: "tv",           label: "TV room",      icon: "tv.fill"),
        .init(id: "reading",      label: "Reading",      icon: "book.fill"),
    ]

    static let outdoor: [ArchetypeOption] = [
        .init(id: "terrace",    label: "Terrace",   icon: "leaf.fill"),
        .init(id: "garden",     label: "Garden",    icon: "leaf.fill"),
        .init(id: "garage",     label: "Garage",    icon: "car.fill"),
        .init(id: "driveway",   label: "Driveway",  icon: "road.lanes"),
        .init(id: "carport",    label: "Carport",   icon: "car.2.fill"),
        .init(id: "porch",      label: "Porch",     icon: "house.and.flag.fill"),
        .init(id: "balcony",    label: "Balcony",   icon: "sun.horizon.fill"),
        .init(id: "pool",       label: "Pool",      icon: "figure.pool.swim"),
        .init(id: "barbecue",   label: "BBQ",       icon: "flame.fill"),
    ]

    static let other: [ArchetypeOption] = [
        .init(id: "hallway",      label: "Hallway",    icon: "door.left.hand.open"),
        .init(id: "staircase",    label: "Staircase",  icon: "stairs"),
        .init(id: "closet",       label: "Closet",     icon: "tshirt.fill"),
        .init(id: "storage",      label: "Storage",    icon: "archivebox.fill"),
        .init(id: "laundry_room", label: "Laundry",    icon: "washer.fill"),
        .init(id: "toilet",       label: "Toilet",     icon: "toilet.fill"),
        .init(id: "attic",        label: "Attic",      icon: "triangle.fill"),
        .init(id: "front_door",   label: "Front door", icon: "sensor.tag.radiowaves.forward.fill"),
        .init(id: "home",         label: "Home",       icon: "house.fill"),
        .init(id: "upstairs",     label: "Upstairs",   icon: "arrow.up.to.line"),
        .init(id: "downstairs",   label: "Downstairs", icon: "arrow.down.to.line"),
        .init(id: "top_floor",    label: "Top floor",  icon: "building.2.fill"),
    ]
}

// MARK: - EditRoomSheet

struct EditRoomSheet: View {

    // ── Inputs ──────────────────────────────────────────────
    let room:   RoomDisplayItem
    let isZone: Bool

    // ── Callbacks ────────────────────────────────────────────
    let onSave: (String, String) -> Void   // (newName, newArchetype)

    // ── State ────────────────────────────────────────────────
    @State private var name:              String
    @State private var selectedArchetype: String
    @State private var isSaving:          Bool = false
    @FocusState private var nameFocused:  Bool

    @Environment(\.dismiss) private var dismiss

    // Computed label for the entity type
    private var entityLabel: String { isZone ? "Zone" : "Room" }

    init(room: RoomDisplayItem, isZone: Bool, onSave: @escaping (String, String) -> Void) {
        self.room   = room
        self.isZone = isZone
        self.onSave = onSave
        _name              = State(initialValue: room.name)
        _selectedArchetype = State(initialValue: room.archetype ?? "living_room")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.09).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // ── Large archetype preview ────────────────────
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 90, height: 90)
                            Image(systemName: archetypeIcon(for: selectedArchetype))
                                .font(.system(size: 36, weight: .medium))
                                .foregroundStyle(Color(hue: 0.11, saturation: 0.7, brightness: 0.95))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.top, 28)
                        .padding(.bottom, 24)
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selectedArchetype)

                        // ── Name field ─────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NAME")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 20)

                            TextField(entityLabel + " name", text: $name)
                                .font(.system(size: 17))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .padding(.horizontal, 20)
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit { saveIfValid() }
                        }

                        // ── Archetype picker ───────────────────────────
                        archetypeSection("TRADITIONAL", options: ArchetypeOption.traditional)
                        archetypeSection("OUTDOOR", options: ArchetypeOption.outdoor)
                        archetypeSection("OTHER", options: ArchetypeOption.other)

                        Color.clear.frame(height: 32)
                    }
                }
            }
            .navigationTitle("Edit \(entityLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        saveIfValid()
                    } label: {
                        if isSaving {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Text("Save")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(canSave ? Color(hue: 0.11, saturation: 0.9, brightness: 1.0) : .white.opacity(0.3))
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // ── Archetype section ────────────────────────────────────

    @ViewBuilder
    private func archetypeSection(_ title: String, options: [ArchetypeOption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 20)

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 76, maximum: 90), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(options) { option in
                    archetypeCell(option)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 28)
    }

    private func archetypeCell(_ option: ArchetypeOption) -> some View {
        let isSelected = selectedArchetype == option.id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedArchetype = option.id
            }
            HapticManager.shared.light()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected
                              ? Color(hue: 0.11, saturation: 0.8, brightness: 0.9).opacity(0.25)
                              : Color.white.opacity(0.06))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isSelected
                                        ? Color(hue: 0.11, saturation: 0.9, brightness: 1.0)
                                        : Color.white.opacity(0.1),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                    Image(systemName: option.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? Color(hue: 0.11, saturation: 0.9, brightness: 1.0)
                                : Color.white.opacity(0.55)
                        )
                }
                Text(option.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    // ── Helpers ─────────────────────────────────────────────

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func saveIfValid() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        onSave(trimmed, selectedArchetype)
        dismiss()
    }
}
