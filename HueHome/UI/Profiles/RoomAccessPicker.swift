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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                LuminousScreenTitle(title: "Rooms",
                                    eyebrow: "\(selection.count) selected",
                                    eyebrowSymbol: "checkmark.circle.fill",
                                    eyebrowTint: LuminousPalette.cyan,
                                    subtitle: "Only these rooms and zones appear on their phone.")

                if liveGroups.isEmpty {
                    LuminousNotice(text: "No rooms loaded yet. Open the dashboard once so this phone has the bridge's room list, then come back.",
                                   symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber)
                }

                ForEach(bridgeSections, id: \.bridgeID) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            LuminousEyebrow(text: section.name)
                            Spacer()
                            Button(allSelected(section) ? "None" : "All") {
                                HapticManager.shared.selection()
                                toggleAll(section)
                            }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(LuminousPalette.cyan)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(allSelected(section) ? "Select none on \(section.name)" : "Select all on \(section.name)")
                        }
                        .padding(.horizontal, 6)
                        LuminousGroup {
                            ForEach(Array(section.groups.enumerated()), id: \.element.id) { idx, group in
                                groupRow(group)
                                if idx < section.groups.count - 1 { LuminousRowDivider() }
                            }
                        }
                    }
                }

                if !staleSelectedIDs.isEmpty {
                    LuminousGroup(title: "No longer found",
                                  footer: "These were selected before but no bridge reports them anymore (deleted room, removed bridge).") {
                        ForEach(Array(staleSelectedIDs.enumerated()), id: \.element) { idx, staleID in
                            LuminousRow(symbol: "questionmark.circle", tint: LuminousPalette.amber, title: "Unknown room") {
                                Button("Remove") {
                                    selection.removeAll { $0 == staleID }
                                }
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(LuminousPalette.amber)
                                .frame(minWidth: 44, minHeight: 44)
                            }
                            if idx < staleSelectedIDs.count - 1 { LuminousRowDivider() }
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet], intensity: 0.6) }
        .luminousPageChrome(title: "Rooms")
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
            HapticManager.shared.selection()
            if isSelected {
                selection.removeAll { $0 == group.id }
            } else {
                selection.append(group.id)
            }
        } label: {
            LuminousRow(symbol: group.kind == .zone ? "square.3.layers.3d" : archetypeIcon(for: group.archetype),
                        tint: isSelected ? LuminousPalette.cyan : LuminousPalette.inkSecondary,
                        title: group.kind == .zone ? "\(group.name) (Zone)" : group.name) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
                    .shadow(color: isSelected ? LuminousPalette.cyan.opacity(0.6) : .clear, radius: 6)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(LuminousRowButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
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
