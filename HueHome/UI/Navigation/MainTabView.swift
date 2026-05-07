// MainTabView.swift
// CastChroma — Navigation Shell
// v0.15.0: Replaced Effects + Sync tabs with unified Studio tab and More hub.
// iPhone: custom floating capsule tab bar (ZStack opacity switcher).
// iPad: NavigationSplitView (sidebar + detail).

import SwiftUI

// MARK: - Tab Definition

enum HueTab: Int, CaseIterable {
    case home    = 0
    case scenes  = 1
    case studio  = 2
    case more    = 3

    var icon: String {
        switch self {
        case .home:   return "house.fill"
        case .scenes: return "sparkles"
        case .studio: return "paintpalette.fill"
        case .more:   return "ellipsis.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .home:   return "Home"
        case .scenes: return "Scenes"
        case .studio: return "Studio"
        case .more:   return "More"
        }
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var selectedTab: HueTab = .home
    /// Tabs whose root view has been constructed at least once — avoids building Studio/Scenes/More until first visit (reduces cold-launch work).
    @State private var realizedTabs: Set<HueTab> = [.home]

    var body: some View {
        if sizeClass == .regular {
            iPadLayout
        } else {
            iPhoneLayout
        }
    }

    // MARK: iPhone Layout

    private var iPhoneLayout: some View {
        ZStack(alignment: .bottom) {
            // Sizing anchor — guarantees the shell accepts the full proposed
            // width on compact devices (iPhone SE / mini) where opacity-switcher
            // children can otherwise collapse to intrinsic widths.
            Color.clear
                .ignoresSafeArea()

            // Opacity-based switcher — preserves NavigationStack state per tab
            // and eliminates the TabView swipe-between-tabs gesture entirely.
            ForEach(HueTab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // HueTabBar is a custom floating capsule in the ZStack;
                    // the system safe area has no knowledge of it.
                    // Height: icon(32) + padding.vertical(12*2) + padding.bottom(8) = 64pt
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: 64)
                    }
                    .opacity(selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(selectedTab == tab)
            }
            HueTabBar(selectedTab: $selectedTab, realizedTabs: $realizedTabs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            realizedTabs.insert(selectedTab)
        }
        .onChange(of: selectedTab) { _, newTab in
            realizedTabs.insert(newTab)
        }
    }

    // MARK: iPad Layout

    private var iPadLayout: some View {
        NavigationSplitView {
            List {
                ForEach(HueTab.allCases, id: \.self) { tab in
                    Button {
                        realizedTabs.insert(tab)
                        selectedTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .foregroundStyle(
                                selectedTab == tab
                                    ? (colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight)
                                    : (colorScheme == .dark ? HuePalette.Noir.textSecondary : HuePalette.Estate.textSecondary)
                            )
                    }
                    .listRowBackground(
                        selectedTab == tab
                            ? (colorScheme == .dark ? HuePalette.amber.opacity(0.12) : HuePalette.amberLight.opacity(0.10))
                            : Color.clear
                    )
                }
            }
            .navigationTitle("ChromaGlow")
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
        } detail: {
            tabContent(for: selectedTab)
        }
        .onAppear {
            realizedTabs.insert(selectedTab)
        }
        .onChange(of: selectedTab) { _, newTab in
            realizedTabs.insert(newTab)
        }
    }

    // MARK: Tab Content Router

    @ViewBuilder
    private func tabContent(for tab: HueTab) -> some View {
        switch tab {
        case .home:
            NavigationStack { DashboardView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .scenes:
            Group {
                if realizedTabs.contains(.scenes) {
                    NavigationStack { ScenesTabView() }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .studio:
            Group {
                if realizedTabs.contains(.studio) {
                    NavigationStack { StudioView() }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .more:
            Group {
                if realizedTabs.contains(.more) {
                    NavigationStack { MoreView() }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Custom Glassmorphic Tab Bar

struct HueTabBar: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var selectedTab: HueTab
    @Binding var realizedTabs: Set<HueTab>
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HueTab.allCases, id: \.self) { tab in
                HueTabItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    namespace: animation
                ) {
                    realizedTabs.insert(tab)
                    withAnimation(HueAnimation.toggle) {
                        selectedTab = tab
                    }
                    HapticManager.shared.light()
                }
            }
        }
        .padding(.horizontal, HueSpacing.xl)
        .padding(.vertical, HueSpacing.md)
        .background {
            Capsule()
                .fill(
                    colorScheme == .dark
                        ? HuePalette.Noir.tabBar.opacity(0.92)
                        : HuePalette.Estate.tabBar.opacity(0.96)
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.40 : 0.12),
                    radius: 20, x: 0, y: 8
                )
        }
        .padding(.horizontal, HueSpacing.xl)
        .padding(.bottom, 8)           // closer to home indicator — less overlap with cards
        .contentShape(Rectangle())     // entire bar frame absorbs taps; nothing bleeds through
    }
}

// MARK: - Tab Item

struct HueTabItem: View {
    @Environment(\.colorScheme) var colorScheme
    let tab: HueTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(
                                colorScheme == .dark
                                    ? HuePalette.amber.opacity(0.18)
                                    : HuePalette.amberLight.opacity(0.15)
                            )
                            .frame(width: 44, height: 32)
                            .matchedGeometryEffect(id: "tabIndicator", in: namespace)
                    }

                    Image(systemName: tab.icon)
                        .font(.system(size: 20, weight: .medium))
                        .symbolEffect(.bounce, value: isSelected)
                        .foregroundStyle(
                            isSelected
                                ? (colorScheme == .dark ? HuePalette.amber : HuePalette.amberLight)
                                : (colorScheme == .dark ? HuePalette.Noir.tabInactive : HuePalette.Estate.tabInactive)
                        )
                        .frame(width: 44, height: 32)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}
