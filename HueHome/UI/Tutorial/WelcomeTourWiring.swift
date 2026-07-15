// WelcomeTourWiring.swift
// ChromaGlow — first-arrival auto-present for the Welcome Tour
//
// The StudioDrainWiring pattern: a small ViewModifier applied to MainTabView
// in AppRootView, so no large view body grows. It decides WHEN the tour
// shows; WHAT it shows lives in TutorialCatalog and WelcomeTourView.
//
// Rules it enforces:
//  · Once. `castchroma.hasSeenWelcomeTour` is set only by Skip/Done — a
//    kill mid-tour means "not seen" and the tour returns next launch.
//  · Never over a deep link. A widget/Siri/invite cold start owns the
//    launch; suppression does NOT mark the tour seen.
//  · Truthful audience. Presentation waits for the first loadAll to settle
//    (3s cap, demo-exempt — the prewarmDeferredTabs pattern) so
//    guestAccessInfo is real before the guest filter snapshots the pages.

import SwiftUI

struct WelcomeTourWiring: ViewModifier {
    @AppStorage("castchroma.hasSeenWelcomeTour") private var hasSeenWelcomeTour = false
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showTour = false
    @State private var tourPages: [TutorialPage] = []

    func body(content: Content) -> some View {
        content
            .task { await autoPresentIfNeeded() }
            .fullScreenCover(isPresented: $showTour) {
                WelcomeTourView(pages: tourPages) {
                    hasSeenWelcomeTour = true
                    showTour = false
                }
            }
    }

    private func autoPresentIfNeeded() async {
        guard !hasSeenWelcomeTour else { return }
        // Let the first frame paint and any cold-start URL / Siri intent land.
        try? await Task.sleep(for: .milliseconds(700))
        // Wait for the first loadAll to settle so guestAccessInfo is truthful.
        let deadline = ContinuousClock.now + .seconds(3)
        while (orchestrator.isLoading || orchestrator.lastLoadedAt == .distantPast),
              !orchestrator.isDemoMode,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, !showTour, !hasSeenWelcomeTour else { return }
        // openToken != 0 catches the plain lightshade://dashboard cold start,
        // which bumps the token without setting any pending field.
        let deepLinkBusy = deepLink.hasPendingRoute || deepLink.openToken != 0
        guard TutorialCatalog.shouldAutoPresent(hasSeenTour: hasSeenWelcomeTour,
                                                hasPendingDeepLink: deepLinkBusy) else { return }
        // Snapshot the audience now — a mid-tour grant update must not shift
        // the page count under the user's thumb.
        tourPages = TutorialCatalog.pages(includeStudioSuite:
            !(orchestrator.guestAccessInfo.isGuestOnly && !orchestrator.isDemoMode))
        showTour = true
    }
}
