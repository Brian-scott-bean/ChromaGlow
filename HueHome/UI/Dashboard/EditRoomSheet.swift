// EditRoomSheet.swift
// CastChroma — Room & Zone CRUD
//
// Sheet for renaming a room/zone and picking a new icon — presented from the
// Room page's overflow menu (Edit Room / Edit Zone). Luminous glass.

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
        .init(id: "studio",       label: "Studio",       icon: "music.mic"),
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // ── The room's icon, glowing ───────────────────
                    LuminousIconBadge(symbol: archetypeIcon(for: selectedArchetype),
                                      tint: LuminousPalette.cyan, size: 92)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selectedArchetype)

                    // ── Name ───────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        LuminousEyebrow(text: "Name")
                            .padding(.horizontal, 6)
                        TextField(entityLabel + " name", text: $name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LuminousPalette.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .luminousGlass(radius: 16)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { saveIfValid() }
                    }

                    // ── Icon picker ────────────────────────────────
                    archetypeSection("Traditional", options: ArchetypeOption.traditional)
                    archetypeSection("Outdoor", options: ArchetypeOption.outdoor)
                    archetypeSection("Other", options: ArchetypeOption.other)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background { LuminousAmbience(colors: [LuminousPalette.cyan.opacity(0.6)]) }
            .navigationTitle("Edit \(entityLabel)")
            .luminousNavigationChrome(title: "Edit \(entityLabel)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveIfValid()
                    } label: {
                        if isSaving {
                            ProgressView().tint(LuminousPalette.ink).scaleEffect(0.85)
                        } else {
                            Text("Save")
                                .font(.body.weight(.bold))
                                .foregroundStyle(canSave ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
        .luminousSheet()
    }

    // ── Archetype section ────────────────────────────────────

    @ViewBuilder
    private func archetypeSection(_ title: String, options: [ArchetypeOption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousEyebrow(text: title)
                .padding(.horizontal, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 90), spacing: 10)], spacing: 12) {
                ForEach(options) { option in
                    archetypeCell(option)
                }
            }
            .padding(12)
            .luminousGlass(radius: 20)
        }
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
                LuminousIconBadge(symbol: option.icon,
                                  tint: isSelected ? LuminousPalette.cyan : LuminousPalette.ink,
                                  size: 48, lit: isSelected)
                Text(option.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? LuminousPalette.ink : LuminousPalette.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(LuminousPressStyle(scale: 0.92))
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
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
