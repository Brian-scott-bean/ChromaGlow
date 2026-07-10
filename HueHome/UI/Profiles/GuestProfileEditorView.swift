// GuestProfileEditorView.swift
// ChromaGlow — Family Sharing Phase 3 (profile create/edit)
//
// Name, icon, color, features, rooms. Feature rows carry the honest
// one-liners (scenes = recall only; guests can never create or delete).
// The rooms row pushes RoomAccessPicker inside the scaffold's own
// NavigationStack. Nothing persists until Save.

import SwiftUI
import SwiftData

struct GuestProfileEditorView: View {

    /// nil = create a new profile.
    let profile: GuestProfile?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "person.fill"
    @State private var colorHex = "#FFB000"
    @State private var features: Set<String> = Set(GuestFeature.all)
    @State private var allowedGroupIDs: [String] = []
    @State private var loaded = false

    private static let icons = [
        "person.fill", "person.2.fill", "figure.child", "figure.wave",
        "graduationcap.fill", "pawprint.fill", "gamecontroller.fill", "briefcase.fill",
    ]
    private static let colors = [
        "#FFB000", "#FF6B6B", "#8C59FF", "#40D9BF", "#668AFF", "#FF9ECF",
    ]

    var body: some View {
        StageSheetScaffold(title: profile == nil ? "New Profile" : "Edit Profile") {
            StageCard(icon: "textformat", title: "Name") {
                TextField("Family member or guest", text: $name)
                    .font(HueFont.stageControl)
                    .foregroundStyle(StagePalette.ink)
                    .textInputAutocapitalization(.words)
                    .padding(.vertical, 6)
            }

            StageCard(icon: "face.smiling", title: "Icon & color") {
                VStack(spacing: HueSpacing.md) {
                    HStack(spacing: HueSpacing.sm) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            Button {
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(icon == symbol ? Color(hex: colorHex) : StagePalette.muted)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle().fill(icon == symbol
                                            ? Color(hex: colorHex).opacity(0.2)
                                            : Color.white.opacity(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: HueSpacing.sm) {
                        ForEach(Self.colors, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if colorHex == hex {
                                            Circle().strokeBorder(.white, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
            }

            StageCard(icon: "checklist", title: "What they can do") {
                VStack(spacing: HueSpacing.sm) {
                    featureToggle(
                        GuestFeature.onOff,
                        title: "Lights on / off",
                        detail: "Room and light power, plus All Off."
                    )
                    featureToggle(
                        GuestFeature.brightness,
                        title: "Brightness & color",
                        detail: "Dim and recolor the lights they can see."
                    )
                    featureToggle(
                        GuestFeature.scenes,
                        title: "Scenes",
                        detail: "Recall existing scenes only — guests can never create or delete."
                    )
                }
            }

            StageCard(icon: "square.grid.2x2", title: "Rooms") {
                NavigationLink {
                    RoomAccessPicker(selection: $allowedGroupIDs)
                } label: {
                    HStack {
                        Text(allowedGroupIDs.isEmpty
                             ? "No rooms selected yet"
                             : "\(allowedGroupIDs.count) room\(allowedGroupIDs.count == 1 ? "" : "s") selected")
                            .font(HueFont.stageControl)
                            .foregroundStyle(allowedGroupIDs.isEmpty ? .orange : StagePalette.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StagePalette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            saveButton
        }
        .task { loadOnce() }
    }

    private func featureToggle(_ feature: String, title: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { features.contains(feature) },
            set: { on in
                if on { features.insert(feature) } else { features.remove(feature) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HueFont.stageControl)
                    .foregroundStyle(StagePalette.ink)
                Text(detail)
                    .font(HueFont.stageStatus)
                    .foregroundStyle(StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(HuePalette.amber)
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Label(profile == nil ? "Create Profile" : "Save Changes",
                  systemImage: "checkmark")
                .font(HueFont.stageChip)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: HueRadius.lg)
                        .fill(HuePalette.amber.opacity(canSave ? 0.2 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .tint(canSave ? HuePalette.amber : .gray)
        .disabled(!canSave)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        guard let profile else { return }
        name = profile.name
        icon = profile.icon
        colorHex = profile.colorHex
        features = Set(profile.features)
        allowedGroupIDs = profile.allowedGroupIDs
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let profile {
            profile.name = trimmed
            profile.icon = icon
            profile.colorHex = colorHex
            profile.features = Array(features)
            profile.allowedGroupIDs = allowedGroupIDs
        } else {
            let created = GuestProfile(
                name: trimmed,
                icon: icon,
                colorHex: colorHex,
                allowedGroupIDs: allowedGroupIDs,
                features: Array(features)
            )
            modelContext.insert(created)
        }
        try? modelContext.save()
        dismiss()
    }
}
