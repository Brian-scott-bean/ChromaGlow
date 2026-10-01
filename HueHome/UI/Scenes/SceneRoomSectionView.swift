// SceneRoomSectionView.swift
// ChromaGlow — Scenes (Luminous)
//
// One collapsible room/zone section on the Scenes tab: the room's icon, lit
// in the colour of the scene that's on there (dark when none is), its name
// rounded and bold, how many scenes it holds and how many are on, and a
// chevron — above a grid supplied by the parent. Collapse state is owned by
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
            .buttonStyle(LuminousPressStyle(scale: 0.99))
            .accessibilityLabel(accessibilityHeaderLabel)
            .accessibilityHint(isCollapsed ? "Double tap to expand" : "Double tap to collapse")
            .accessibilityAddTraits(.isHeader)

            if !isCollapsed {
                content()
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isCollapsed)
    }

    /// The colour the room's active scene is showing, if one is on.
    private var activeTint: Color? {
        section.scenes.first(where: \.isActive).map { LuminousScenePalette.accent(for: $0) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            LuminousIconBadge(symbol: archetypeIcon(for: section.archetype),
                              tint: activeTint ?? LuminousPalette.inkSecondary,
                              size: 34,
                              lit: activeTint != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(LuminousType.title)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    Text("\(section.scenes.count) scene\(section.scenes.count == 1 ? "" : "s")")
                        .foregroundStyle(LuminousPalette.inkSecondary)
                    if section.activeCount > 0 {
                        Text("·").foregroundStyle(LuminousPalette.inkTertiary)
                        Text("\(section.activeCount) on now")
                            .foregroundStyle(LuminousPalette.live)
                    }
                }
                .font(.footnote.weight(.medium))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LuminousPalette.inkSecondary)
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var accessibilityHeaderLabel: String {
        var parts = ["\(section.title), \(section.scenes.count) scenes"]
        if section.activeCount > 0 { parts.append("\(section.activeCount) active") }
        if isCollapsed { parts.append("collapsed") }
        return parts.joined(separator: ", ")
    }
}
