// GuestProfileEditorView.swift
// ChromaGlow — Family Sharing Phase 3 (profile create/edit)
//
// Name, icon, color, features, rooms. Feature rows carry the honest
// one-liners (scenes = recall only; guests can never create or delete).
// The rooms row pushes RoomAccessPicker inside the scaffold's own
// NavigationStack. Nothing persists until Save. Luminous sheet: the
// background leans to the colour chosen for the person.

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
        LuminousSheetScaffold(title: profile == nil ? "New Profile" : "Edit Profile",
                              eyebrow: "Profiles & Access",
                              eyebrowSymbol: "person.2.fill",
                              tint: Color(hex: colorHex),
                              subtitle: "Who they are, what they may change, and which rooms they see.",
                              ambience: [Color(hex: colorHex), LuminousPalette.violet],
                              detents: [.large]) {
            LuminousTextField(caption: "Name", placeholder: "Family member or guest", text: $name)

            LuminousTitledCard(symbol: icon, title: "Icon & color", tint: Color(hex: colorHex)) {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            let selected = icon == symbol
                            Button {
                                HapticManager.shared.selection()
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(selected ? Color(hex: colorHex) : LuminousPalette.inkSecondary)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(selected ? Color(hex: colorHex).opacity(0.22) : Color.white.opacity(0.05)))
                                    .overlay(Circle().strokeBorder(selected ? Color(hex: colorHex).opacity(0.7) : Color.white.opacity(0.08),
                                                                   lineWidth: 1))
                                    .shadow(color: selected ? Color(hex: colorHex).opacity(0.5) : .clear, radius: 8)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(LuminousPressStyle(scale: 0.9))
                            .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(Self.colors, id: \.self) { hex in
                            let selected = colorHex == hex
                            Button {
                                HapticManager.shared.selection()
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(RadialGradient(colors: [Color.white.opacity(0.6), Color(hex: hex)],
                                                         center: .topLeading, startRadius: 0, endRadius: 26))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0.2), lineWidth: selected ? 2 : 1))
                                    .shadow(color: Color(hex: hex).opacity(selected ? 0.8 : 0.3), radius: selected ? 10 : 4)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(LuminousPressStyle(scale: 0.88))
                            .accessibilityLabel("Color \(hex)")
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            LuminousGroup(title: "What they can do") {
                featureToggle(
                    GuestFeature.onOff,
                    symbol: "power",
                    title: "Lights on / off",
                    detail: "Room and light power, plus All Off."
                )
                LuminousRowDivider()
                featureToggle(
                    GuestFeature.brightness,
                    symbol: "sun.max.fill",
                    title: "Brightness & color",
                    detail: "Dim and recolor the lights they can see."
                )
                LuminousRowDivider()
                featureToggle(
                    GuestFeature.scenes,
                    symbol: "swatchpalette.fill",
                    title: "Scenes",
                    detail: "Recall existing scenes only — guests can never create or delete."
                )
            }

            LuminousGroup(title: "Rooms") {
                NavigationLink {
                    RoomAccessPicker(selection: $allowedGroupIDs)
                } label: {
                    LuminousRow(symbol: "square.grid.2x2.fill",
                                tint: allowedGroupIDs.isEmpty ? LuminousPalette.amber : LuminousPalette.cyan,
                                title: allowedGroupIDs.isEmpty
                                    ? "No rooms selected yet"
                                    : "\(allowedGroupIDs.count) room\(allowedGroupIDs.count == 1 ? "" : "s") selected",
                                subtitle: allowedGroupIDs.isEmpty ? "Pick at least one room before inviting." : "Only these appear on their phone.",
                                subtitleTint: allowedGroupIDs.isEmpty ? LuminousPalette.amber : LuminousPalette.inkSecondary)
                }
                .buttonStyle(LuminousRowButtonStyle())
            }

            saveButton
        }
        .task { loadOnce() }
    }

    private func featureToggle(_ feature: String, symbol: String, title: String, detail: String) -> some View {
        LuminousToggleRow(symbol: symbol, tint: Color(hex: colorHex), title: title, subtitle: detail,
                          isOn: Binding(
                            get: { features.contains(feature) },
                            set: { on in
                                if on { features.insert(feature) } else { features.remove(feature) }
                            }
                          ))
    }

    private var saveButton: some View {
        LuminousPrimaryButton(title: profile == nil ? "Create Profile" : "Save Changes", symbol: "checkmark") {
            save()
        }
        .disabled(!canSave)
        .padding(.top, 4)
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
