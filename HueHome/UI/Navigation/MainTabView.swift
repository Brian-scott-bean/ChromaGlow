// MainTabView.swift
// CastChroma — Navigation Shell
// v0.15.0: Replaced Effects + Sync tabs with unified Studio tab and More hub.
// iPhone: custom floating capsule tab bar (ZStack opacity switcher).
// iPad: NavigationSplitView (sidebar + detail).

import SwiftUI
import SwiftData
import UIKit

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
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var selectedTab: HueTab = .home
    /// Tabs whose root view has been constructed at least once — avoids building Studio/Scenes/More until first visit (reduces cold-launch work).
    @State private var realizedTabs: Set<HueTab> = [.home]
    /// Holds a weak reference to each tab's underlying UINavigationController so a
    /// re-tap on the active tab (or programmatic back) can pop one page.
    @State private var navRegistry = TabNavRegistry()
    /// Home's navigation stack. Owned here so a widget deep link can push a room.
    /// `DashboardView` supplies the matching `.navigationDestination(for:)`.
    @State private var homePath: [RoomDisplayItem] = []
    /// A home-join invite being presented (tapped link / scanned QR while paired).
    @State private var presentedInvite: InvitePresentation?
    /// A token-bearing guest invite being presented (Phase 2).
    @State private var presentedGuestInvite: GuestInvitePresentation?
    @State private var inviteError: InvitePayloadError?
    /// Family Sharing: a Studio-bound deep link arrived on a guest-only shell.
    @State private var showGuestBlockedAlert = false
    /// Family Sharing Phase 4: cooperative-wipe notice / owned-bridge advice.
    @State private var authorizationNotice: String?
    @Environment(\.modelContext) private var modelContext

    private struct InvitePresentation: Identifiable {
        let id = UUID()
        let payload: HomeJoinPayload
    }

    private struct GuestInvitePresentation: Identifiable {
        let id = UUID()
        let payload: GuestInvitePayload
    }

    /// Family Sharing: a guest-only device (every live bridge grant-limited)
    /// has no Studio — its engines need per-light writes and entertainment
    /// streaming that a guest key deliberately can't stream (no clientkey),
    /// and its creations couldn't be saved to anything the guest owns.
    /// Mixed-role devices (own bridge + a granted one) keep the full shell.
    private var visibleTabs: [HueTab] {
        guard orchestrator.guestAccessInfo.isGuestOnly, !orchestrator.isDemoMode else {
            return HueTab.allCases
        }
        return HueTab.allCases.filter { $0 != .studio }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        // If the selected tab disappears (grant arrives mid-session), land
        // on Home rather than a hidden surface.
        .onChange(of: orchestrator.guestAccessInfo) { _, _ in
            if !visibleTabs.contains(selectedTab) {
                withAnimation(HueAnimation.toggle) { selectedTab = .home }
            }
        }
        .task { await prewarmDeferredTabs() }
        // Cold launch from a share link: `onOpenURL` fired (and bumped
        // openToken) before this view existed, so the onChange below never
        // sees it. Route once on mount if a scene is already waiting.
        .task { routePendingShare() }
        // Same cold-launch window for a Siri "start X in Y" — route on mount.
        .task { routePendingStudioAction() }
        // …and for a home-join invite link.
        .task { routePendingInvite() }
        // A widget / Lock-Screen tap deep-links here.
        .onChange(of: deepLink.openToken) { _, _ in consumeDeepLink() }
        // A cold launch from a widget arrives before `loadAll` has any rooms, so
        // the id can't resolve yet. Retry when the groups land.
        .onChange(of: orchestrator.allRooms.count) { _, _ in retryPendingDeepLink() }
        .onChange(of: orchestrator.allZones.count) { _, _ in retryPendingDeepLink() }
        .sheet(item: $presentedInvite) { presentation in
            JoinSharedHomeView(
                payload: presentation.payload,
                isAddingAdditional: true,
                onBridgeAdded: { record in
                    orchestrator.addBridge(record)
                    Task { await orchestrator.loadAll() }
                }
            )
        }
        .sheet(item: $presentedGuestInvite) { presentation in
            // The grant was already written by the accept flow (upsert →
            // updateGuestGrants happen BEFORE this closure), so the first
            // loadAll of the new bridge is filtered from the start.
            GuestInviteAcceptView(
                payload: presentation.payload,
                isAddingAdditional: true,
                onBridgeAdded: { record in
                    orchestrator.addBridge(record)
                    Task { await orchestrator.loadAll() }
                }
            )
        }
        .alert("Can't Open Invite", isPresented: Binding(
            get: { inviteError != nil },
            set: { if !$0 { inviteError = nil } }
        )) {
            Button("OK", role: .cancel) { inviteError = nil }
        } message: {
            Text(inviteError?.localizedDescription ?? "")
        }
        .alert("Not available with guest access", isPresented: $showGuestBlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Studio isn't part of shared access — creating and importing lighting compositions needs the home owner's own connection.")
        }
        // Family Sharing Phase 4: explicit bridge refusals (401/403 on the
        // pinned data plane). Granted bridge → cooperative wipe; owned
        // bridge → re-pair advice, never an auto-wipe.
        .onChange(of: BridgeAuthorizationMonitor.shared.signalToken) { _, _ in
            handleUnauthorizedBridges()
        }
        .alert("Bridge Access", isPresented: Binding(
            get: { authorizationNotice != nil },
            set: { if !$0 { authorizationNotice = nil } }
        )) {
            Button("OK", role: .cancel) { authorizationNotice = nil }
        } message: {
            Text(authorizationNotice ?? "")
        }
    }

    // MARK: - Cooperative wipe (L-30 pattern)

    private func handleUnauthorizedBridges() {
        let monitor = BridgeAuthorizationMonitor.shared
        for bridgeID in monitor.unauthorizedBridgeIDs {
            monitor.clear(bridgeID: bridgeID)
            // A stale signal for an already-removed bridge is ignored.
            guard let name = orchestrator.bridgeName(for: bridgeID) else { continue }

            if orchestrator.isGuestGrantedBridge(bridgeID) {
                // Explicit refusal of a granted key = the owner revoked it.
                // Wipe cooperatively: client, credentials, pin, record, grant.
                Task {
                    await orchestrator.removeBridge(id: bridgeID)
                    // Fetch-all + filter: a handful of records, and #Predicate
                    // trips the KeyPath-Sendable strict-concurrency warning.
                    if let record = ((try? modelContext.fetch(FetchDescriptor<BridgeRecord>())) ?? [])
                        .first(where: { $0.id == bridgeID }) {
                        modelContext.delete(record)
                        try? modelContext.save()
                    }
                    try? GuestAccessGrantStore.deleteGrant(for: bridgeID, modelContext: modelContext)
                    orchestrator.updateGuestGrants(from: modelContext)
                    authorizationNotice =
                        "Your invite to \(name) was revoked, so its key was removed from this phone."
                }
            } else {
                // An OWNED credential hit an explicit refusal (factory reset,
                // keys cleared). Never auto-wipe what the user paired — advise.
                authorizationNotice =
                    "\(name) refused this phone's key. If the bridge was factory-reset or its app keys were cleared, remove it in Bridge Manager and pair again."
            }
        }
    }

    // MARK: - Deep link

    /// Surfaces Home and, when the widget named a room/zone, pushes its detail.
    /// A plain `lightshade://dashboard` tap pops back to the dashboard root.
    /// A share link goes to Studio instead — see `routePendingShare`.
    private func consumeDeepLink() {
        if routePendingInvite() { return }
        if routePendingShare() { return }
        if routePendingStudioAction() { return }

        realizedTabs.insert(.home)
        withAnimation(HueAnimation.toggle) { selectedTab = .home }

        guard let id = deepLink.pendingGroupID else {
            homePath = []
            return
        }
        guard let room = resolveGroup(id) else { return }   // retried on load
        homePath = [room]
        deepLink.pendingGroupID = nil
    }

    /// Surfaces Studio when a share link decoded into a scene (or an error).
    /// Realizing the tab is what makes StudioView's `.task` drain it — Studio
    /// owns the only CompositionStore, so the import must happen there.
    /// Returns true when it took the link.
    @discardableResult
    private func routePendingShare() -> Bool {
        guard deepLink.pendingSharedScene != nil || deepLink.pendingShareError != nil
        else { return false }
        // Guest-only shell has no Studio to import into — say so instead of
        // force-selecting a hidden tab.
        guard visibleTabs.contains(.studio) else {
            deepLink.clearShare()
            showGuestBlockedAlert = true
            return true
        }
        realizedTabs.insert(.studio)
        withAnimation(HueAnimation.toggle) { selectedTab = .studio }
        return true
    }

    /// Surfaces Studio when Siri asked for a composition/effect start.
    /// Realizing the tab is what makes StudioView's drain run — the apply
    /// must go through StudioViewModel so Studio's state stays in sync.
    @discardableResult
    private func routePendingStudioAction() -> Bool {
        guard deepLink.pendingStudioAction != nil else { return false }
        guard visibleTabs.contains(.studio) else {
            deepLink.pendingStudioAction = nil
            showGuestBlockedAlert = true
            return true
        }
        realizedTabs.insert(.studio)
        withAnimation(HueAnimation.toggle) { selectedTab = .studio }
        return true
    }

    private func retryPendingDeepLink() {
        guard let id = deepLink.pendingGroupID, let room = resolveGroup(id) else { return }
        homePath = [room]
        deepLink.pendingGroupID = nil
    }

    /// Presents the join flow for a tapped/scanned home-join invite (or its
    /// decode error). Drains the coordinator — the sheet owns the payload
    /// from here. Returns true when it took the link.
    @discardableResult
    private func routePendingInvite() -> Bool {
        if let payload = deepLink.pendingInvite {
            deepLink.clearInvite()
            presentedInvite = InvitePresentation(payload: payload)
            return true
        }
        if let payload = deepLink.pendingGuestInvite {
            deepLink.clearInvite()
            presentedGuestInvite = GuestInvitePresentation(payload: payload)
            return true
        }
        if let error = deepLink.pendingInviteError {
            deepLink.clearInvite()
            inviteError = error
            return true
        }
        return false
    }

    private func resolveGroup(_ id: String) -> RoomDisplayItem? {
        orchestrator.allRooms.first { $0.id == id }
            ?? orchestrator.allZones.first { $0.id == id }
    }

    /// Build deferred tab roots after Home paints AND the first loadAll has settled,
    /// one tab per main-thread pass. The old version inserted .scenes and .more in the
    /// same transaction ~440ms after appear — on a fresh pairing that first-compiled
    /// three heavy tab trees in one pass, colliding with loadAll completion, the
    /// first-time cache write, and SSE connects (device logs showed a gesture-gate
    /// timeout at exactly that moment). Hard 3s cap: prewarm always happens even if
    /// the bridge fetch hangs. First TAP on an unrealized tab still realizes it
    /// instantly via HueTabBar / swipe / onChange(selectedTab) inserts regardless.
    private func prewarmDeferredTabs() async {
        StartupTimeline.mark("prewarm.wait-begin")
        try? await Task.sleep(for: .milliseconds(280))          // let Home paint
        let deadline = ContinuousClock.now + .seconds(3)
        while (orchestrator.isLoading || orchestrator.lastLoadedAt == .distantPast),
              !orchestrator.isDemoMode,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        StartupTimeline.mark(
            "prewarm.released",
            ContinuousClock.now >= deadline ? "3s CAP HIT — loadAll still not settled" : "loadAll settled"
        )
        try? await Task.sleep(for: .milliseconds(250))          // settle gap: cache write / widget publish
        guard !Task.isCancelled else { return }
        if visibleTabs.contains(.studio) {
            realizedTabs.insert(.studio)
            StartupTimeline.mark("prewarm.studio")
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))
        realizedTabs.insert(.scenes)
        StartupTimeline.mark("prewarm.scenes")
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))
        realizedTabs.insert(.more)
        StartupTimeline.mark("prewarm.more")
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
            ForEach(visibleTabs, id: \.self) { tab in
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
                    // Pause off-screen tabs' animation clocks (kept mounted for state).
                    .environment(\.isTabActive, selectedTab == tab)
            }
            HueTabBar(tabs: visibleTabs, selectedTab: $selectedTab,
                      realizedTabs: $realizedTabs, navRegistry: navRegistry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(tabSwipeGesture)
        .onAppear {
            realizedTabs.insert(selectedTab)
        }
        .onChange(of: selectedTab) { _, newTab in
            realizedTabs.insert(newTab)
        }
    }

    /// Full-screen horizontal swipe to move between bottom tabs.
    /// Attached as a low-priority `.gesture` so inner horizontal scrollers and Studio's
    /// deck pager (which claim their own drags) win; only "unclaimed" horizontal swipes
    /// on the page body change tabs. Left-edge swipes are ignored so the system
    /// interactive back-swipe inside a NavigationStack keeps working.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.startLocation.x > 24 else { return }   // preserve edge-back
                let dx = value.translation.width
                let dy = value.translation.height
                let predictedX = value.predictedEndTranslation.width
                // Require a decisive, predominantly horizontal swipe.
                guard abs(dx) > abs(dy) * 1.3,
                      abs(dx) > 60 || abs(predictedX) > 120 else { return }
                // Index into visibleTabs, not rawValue arithmetic — a hidden
                // Studio tab must not be a swipe stop (guest-only shell).
                let tabs = visibleTabs
                guard let current = tabs.firstIndex(of: selectedTab) else { return }
                let target = current + (dx < 0 ? 1 : -1)
                guard tabs.indices.contains(target) else { return }
                let next = tabs[target]
                guard next != selectedTab else { return }
                realizedTabs.insert(next)
                withAnimation(HueAnimation.toggle) { selectedTab = next }
                HapticManager.shared.light()
            }
    }

    // MARK: iPad Layout

    private var iPadLayout: some View {
        NavigationSplitView {
            List {
                ForEach(visibleTabs, id: \.self) { tab in
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
            // Path-bound so a widget deep link can push a room. The tab bar's
            // re-tap-to-pop still drives the UINavigationController directly;
            // SwiftUI mirrors that pop back into `homePath`.
            NavigationStack(path: $homePath) {
                DashboardView()
                    .background(NavControllerResolver { navRegistry.register(.home, $0) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .scenes:
            Group {
                if realizedTabs.contains(.scenes) {
                    NavigationStack {
                        ScenesTabView()
                            .background(NavControllerResolver { navRegistry.register(.scenes, $0) })
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .studio:
            Group {
                if realizedTabs.contains(.studio) {
                    NavigationStack {
                        StudioView()
                            .background(NavControllerResolver { navRegistry.register(.studio, $0) })
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .more:
            Group {
                if realizedTabs.contains(.more) {
                    NavigationStack {
                        MoreView()
                            .background(NavControllerResolver { navRegistry.register(.more, $0) })
                    }
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
    /// The tabs to render — MainTabView passes visibleTabs (guest-only
    /// devices drop Studio). Defaulted so previews/other callers keep the
    /// full set.
    var tabs: [HueTab] = HueTab.allCases
    @Binding var selectedTab: HueTab
    @Binding var realizedTabs: Set<HueTab>
    let navRegistry: TabNavRegistry
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                HueTabItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    namespace: animation
                ) {
                    if selectedTab == tab {
                        // Already on this tab → back out one page in its menu stack.
                        if navRegistry.popOne(tab) {
                            HapticManager.shared.light()
                        }
                    } else {
                        realizedTabs.insert(tab)
                        withAnimation(HueAnimation.toggle) {
                            selectedTab = tab
                        }
                        HapticManager.shared.light()
                    }
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

// MARK: - Per-Tab Navigation Controller Registry
//
// The custom tab bar keeps all four tab NavigationStacks alive in a ZStack, so
// there is no system "tap active tab to pop" behavior. We capture each tab's
// underlying UINavigationController and pop one page on re-tap. Popping through
// the nav controller is the same path the interactive edge-swipe-back uses, so
// SwiftUI reconciles its own navigation state (value-, boolean-, and view-based
// destinations alike) — no need to rewire the tabs to a bound NavigationPath.

@MainActor
@Observable
final class TabNavRegistry {
    private final class WeakNav { weak var controller: UINavigationController?; init(_ c: UINavigationController?) { controller = c } }
    @ObservationIgnored private var controllers: [HueTab: WeakNav] = [:]

    func register(_ tab: HueTab, _ controller: UINavigationController?) {
        guard let controller else { return }
        controllers[tab] = WeakNav(controller)
    }

    /// Pops one page from the tab's stack if it is deeper than its root. Returns true if it popped.
    @discardableResult
    func popOne(_ tab: HueTab) -> Bool {
        guard let nc = controllers[tab]?.controller, nc.viewControllers.count > 1 else { return false }
        nc.popViewController(animated: true)
        return true
    }
}

/// Invisible bridge that resolves the UINavigationController backing the SwiftUI
/// NavigationStack it is placed inside, and hands it back via `onResolve`.
struct NavControllerResolver: UIViewControllerRepresentable {
    let onResolve: (UINavigationController?) -> Void

    func makeUIViewController(context: Context) -> ResolverController {
        ResolverController(onResolve: onResolve)
    }

    func updateUIViewController(_ controller: ResolverController, context: Context) {
        controller.resolve()
    }

    final class ResolverController: UIViewController {
        let onResolve: (UINavigationController?) -> Void

        init(onResolve: @escaping (UINavigationController?) -> Void) {
            self.onResolve = onResolve
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                self?.onResolve(self?.navigationController)
            }
        }
    }
}

// MARK: - Tab visibility environment

/// True when the enclosing tab is the visible one. The iPhone shell keeps all
/// realized tabs mounted in an opacity switcher (preserving each tab's nav +
/// scroll state), so per-card animation clocks (PatternStripView, StudioCardCanvas,
/// beat meters) read this to pause while their tab is off-screen instead of
/// redrawing forever behind the visible tab. Defaults to `true` so sheets,
/// full-screen covers (Perform), iPad detail, and previews animate normally.
private struct TabActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var isTabActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}
