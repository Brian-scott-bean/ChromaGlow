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
//  · Verified presentation. A racing presentation from a hidden tab can
//    make UIKit silently drop this cover (the prewarmed Studio tab's
//    photosensitivity alert did exactly that before it was gated on
//    \.isTabActive). The cover reports its own appearance; if it never
//    arrives, the flag flips off and on once to re-request presentation.

import SwiftUI

/// The presented tour, as an item so the pages ride the presentation
/// atomically — `isPresented:` + separate page state can build the cover
/// against stale state (the build-14 Perform black-page bug, same fix).
struct TourPresentation: Identifiable, Equatable {
    /// Bumped per presentation attempt so a retry re-presents cleanly.
    let id: Int
    let pages: [TutorialPage]
    /// True for the versioned "What's New" mini-deck (new pages only) shown
    /// to users who completed an older tour. Defaulted so the full-tour and
    /// MoreView replay call sites compile unchanged.
    var isWhatsNew: Bool = false
}

struct WelcomeTourWiring: ViewModifier {
    @AppStorage("castchroma.hasSeenWelcomeTour") private var hasSeenWelcomeTour = false
    /// Highest catalog version this user has finished seeing. 0 = key absent
    /// (legacy install, folded to "saw v1" by shouldPresentWhatsNew). Stamped
    /// by BOTH finishes: the full tour and the What's New deck.
    @AppStorage("castchroma.seenTourVersion") private var seenTourVersion = 0
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var tourPresentation: TourPresentation?
    @State private var tourSurfaceVisible = false

    func body(content: Content) -> some View {
        content
            .task { await autoPresentIfNeeded() }
            .fullScreenCover(item: $tourPresentation) { presentation in
                WelcomeTourView(pages: presentation.pages,
                                headerTitle: presentation.isWhatsNew ? "WHAT'S NEW" : "WELCOME TOUR") {
                    if !presentation.isWhatsNew { hasSeenWelcomeTour = true }
                    seenTourVersion = TutorialCatalog.catalogVersion
                    tourPresentation = nil
                }
                .onAppear { tourSurfaceVisible = true }
                .onDisappear { tourSurfaceVisible = false }
            }
    }

    private func autoPresentIfNeeded() async {
        guard !hasSeenWelcomeTour || seenTourVersion < TutorialCatalog.catalogVersion
        else { return }
        // Let the first frame paint and any cold-start URL / Siri intent land.
        try? await Task.sleep(for: .milliseconds(700))
        // Wait for the first loadAll to settle so guestAccessInfo is truthful.
        let deadline = ContinuousClock.now + .seconds(3)
        while (orchestrator.isLoading || orchestrator.lastLoadedAt == .distantPast),
              !orchestrator.isDemoMode,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, tourPresentation == nil else { return }
        // openToken != 0 catches the plain lightshade://dashboard cold start,
        // which bumps the token without setting any pending field.
        let deepLinkBusy = deepLink.hasPendingRoute || deepLink.openToken != 0
        // Snapshot the audience now — a mid-tour grant update must not shift
        // the page count under the user's thumb.
        let includeStudioSuite =
            !(orchestrator.guestAccessInfo.isGuestOnly && !orchestrator.isDemoMode)

        let presentation: TourPresentation
        if TutorialCatalog.shouldAutoPresent(hasSeenTour: hasSeenWelcomeTour,
                                             hasPendingDeepLink: deepLinkBusy) {
            let pages = TutorialCatalog.pages(includeStudioSuite: includeStudioSuite)
            debugLog("[Tour] auto-presenting (\(pages.count) pages)")
            presentation = TourPresentation(id: 1, pages: pages)
        } else if TutorialCatalog.shouldPresentWhatsNew(hasSeenTour: hasSeenWelcomeTour,
                                                        lastSeenVersion: seenTourVersion,
                                                        hasPendingDeepLink: deepLinkBusy) {
            let newPages = TutorialCatalog.whatsNewPages(
                sinceVersion: max(1, seenTourVersion),
                includeStudioSuite: includeStudioSuite)
            // Guest shells may see nothing new — present nothing AND stamp
            // nothing, so the check re-runs if this device gains owner
            // access later. Deep-link suppression likewise stamps nothing.
            guard !newPages.isEmpty else { return }
            debugLog("[Tour] what's-new presenting (\(newPages.count) pages)")
            presentation = TourPresentation(id: 1, pages: newPages, isWhatsNew: true)
        } else {
            return
        }
        tourPresentation = presentation

        // Verify the cover actually presented; re-request once if it was
        // swallowed by a racing presentation (see header comment).
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, tourPresentation != nil, !tourSurfaceVisible else { return }
        debugLog("[Tour] cover was dropped — re-requesting presentation")
        tourPresentation = nil
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, tourPresentation == nil else { return }
        tourPresentation = TourPresentation(id: 2, pages: presentation.pages,
                                            isWhatsNew: presentation.isWhatsNew)
    }
}

/// DEBUG-only console diagnostics (house convention — see UnifiedOrchestrator).
/// Release builds compile the call away.
fileprivate func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
