// MainTabView.swift
// HueHome Pro — Stage 1 Navigation
// Custom glassmorphic 5-tab shell.
// iPhone: TabView + NavigationStack per tab.
// iPad: NavigationSplitView (sidebar + detail).

import SwiftUI

// MARK: - Tab Definition

enum HueTab: Int, CaseIterable {
    case home     = 0
    case scenes   = 1
    case effects  = 2
    case settings = 3

    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .scenes:   return "sparkles"
        case .effects:  return "wand.and.stars"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .home:     return "Home"
        case .scenes:   return "Scenes"
        case .effects:  return "Effects"
        case .settings: return "Settings"
        }
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var selectedTab: HueTab = .home

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
            TabView(selection: $selectedTab) {
                ForEach(HueTab.allCases, id: \.self) { tab in
                    tabContent(for: tab)
                        .tag(tab)
                }
            }
            .toolbar(.hidden, for: .tabBar)

            HueTabBar(selectedTab: $selectedTab)
        }
    }

    // MARK: iPad Layout

    private var iPadLayout: some View {
        NavigationSplitView {
            List {
                ForEach(HueTab.allCases, id: \.self) { tab in
                    Button {
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
            .navigationTitle("HueHome Pro")
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
        } detail: {
            tabContent(for: selectedTab)
        }
    }

    // MARK: Tab Content Router

    @ViewBuilder
    private func tabContent(for tab: HueTab) -> some View {
        switch tab {
        case .home:
            NavigationStack { DashboardView() }
        case .scenes:
            NavigationStack { ScenesTabView() }
        case .effects:
            NavigationStack { EffectsTabView() }
        case .settings:
            NavigationStack { SettingsTabView() }
        }
    }
}

// MARK: - Custom Glassmorphic Tab Bar

struct HueTabBar: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var selectedTab: HueTab
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HueTab.allCases, id: \.self) { tab in
                HueTabItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    namespace: animation
                ) {
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
        .padding(.bottom, HueSpacing.lg)
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
