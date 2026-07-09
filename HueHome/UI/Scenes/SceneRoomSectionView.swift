// SceneRoomSectionView.swift
// ChromaGlow — Scenes overhaul Phase 1
//
// One collapsible room/zone section on the Scenes tab: stage-styled header
// (archetype icon, name, scene-count badge, ACTIVE badge, chevron) above a
// content grid supplied by the parent. Collapse state is owned by
// ScenesTabView (persisted CSV) so it survives relaunches.

import SwiftUI

struct SceneRoomSectionView<Content: View>: View {

    let section: SceneGrouping.SceneSection
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleCollapse) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityHeaderLabel)
            .accessibilityHint(isCollapsed ? "Double tap to expand" : "Double tap to collapse")

            if !isCollapsed {
                content()
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isCollapsed)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: archetypeIcon(for: section.archetype))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HuePalette.amber.opacity(0.85))
                .frame(width: 22)

            Text(section.title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(StagePalette.ink)
                .lineLimit(1)

            StageBadge(
                text: "\(section.scenes.count) SCENE\(section.scenes.count == 1 ? "" : "S")",
                style: .muted
            )

            if section.activeCount > 0 {
                StageBadge(text: "ACTIVE", style: .live)
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StagePalette.muted)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var accessibilityHeaderLabel: String {
        var parts = ["\(section.title), \(section.scenes.count) scenes"]
        if section.activeCount > 0 { parts.append("\(section.activeCount) active") }
        if isCollapsed { parts.append("collapsed") }
        return parts.joined(separator: ", ")
    }
}
