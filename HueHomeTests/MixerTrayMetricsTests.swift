// MixerTrayMetricsTests.swift
// HueHome Pro — Unit Tests
//
// The "rows pay for themselves" contract: every mixer-tray row's declared
// metric must cover its content, and growing a row's visuals means growing
// its constant here — otherwise the tray clips. Pins the 44pt-hit-target
// pass (40pt transport circles, 36pt grab bar, 28pt badge lane).

import XCTest
import SwiftUI
@testable import HueHome

final class MixerTrayMetricsTests: XCTestCase {

    func testHeaderRowFloors() {
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.grabBarHeight, 36)
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.headerHeight, 66,
                                    "row 1 must cover the 40pt action circles plus padding")
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.badgeLaneHeight, 28)
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.statusLineHeight, 26)
    }

    func testHeaderBlockArithmetic() {
        XCTAssertEqual(
            MixerTrayMetrics.headerBlockHeight(hasStatusLine: false),
            MixerTrayMetrics.headerHeight + HueSpacing.xs + MixerTrayMetrics.badgeLaneHeight
        )
        XCTAssertEqual(
            MixerTrayMetrics.headerBlockHeight(hasStatusLine: true),
            MixerTrayMetrics.headerHeight + HueSpacing.xs + MixerTrayMetrics.badgeLaneHeight
                + HueSpacing.xs + MixerTrayMetrics.statusLineHeight
        )
    }

    // MARK: - Bottom clearance
    //
    // The tray is bottom-anchored inside a region the music bar's safeAreaInset
    // has already floored at the bar's top edge. Re-adding tabBarClearance
    // there padded the tray off a floor it was already on (~200pt of dead
    // band). These pin the two halves of that contract.

    /// A realistic `safeAreaInsets.bottom` while the music bar is mounted:
    /// the bar itself, its 70pt tab-bar padding, and the home indicator.
    private let musicBarInset: CGFloat = 165

    func testTabBarClearanceFloor() {
        XCTAssertEqual(MixerTrayMetrics.tabBarClearance(bottomInset: 0), 72,
                       "the 72pt floor must survive the move off StudioView")
        XCTAssertEqual(MixerTrayMetrics.tabBarClearance(bottomInset: 34), 90)
    }

    func testMountedBarReclaimsTheBand() {
        let mounted = MixerTrayMetrics.bottomClearance(bottomInset: musicBarInset,
                                                       barMounted: true)
        XCTAssertEqual(mounted, HueSpacing.sm,
                       "with the bar up the tray owes only a card-to-card gap")
        XCTAssertLessThan(mounted, MixerTrayMetrics.tabBarClearance(bottomInset: musicBarInset),
                          "the dead band must actually be reclaimed")
    }

    /// Bar suppressed (≤700pt phone with a running effect): nothing else clears
    /// the tab bar, so the full figure is owed and `reclaimed` is exactly 0 —
    /// compact geometry stays byte-identical to before the change.
    func testSuppressedBarKeepsFullClearance() {
        for inset in [CGFloat(0), 34, musicBarInset] {
            XCTAssertEqual(
                MixerTrayMetrics.bottomClearance(bottomInset: inset, barMounted: false),
                MixerTrayMetrics.tabBarClearance(bottomInset: inset),
                "suppressed bar must owe the full tab-bar clearance at inset \(inset)"
            )
        }
    }

    /// Compact devices must keep at least three inline slider rows after any
    /// header growth (the cap otherwise silently eats slider rows).
    func testCompactCapCoversHeaderGrowth() {
        let needed = MixerTrayMetrics.grabBarHeight
            + MixerTrayMetrics.headerBlockHeight(hasStatusLine: false)
            + 3 * MixerTrayMetrics.sliderRowHeight
            + MixerTrayMetrics.verticalPadding
            + MixerTrayMetrics.moreRowHeight
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.compactHeightCap, needed)
    }

    // ── Selector vs effect panel (hardware convergence slice D) ─────────
    //
    // Reported from the device: scrolling the room/zone wheel onto a room with
    // a running effect made the customization panel appear over it, and the
    // panel could "appear and collapse immediately". Both symptoms come from
    // one line — the room-change handler opening the tray — because an open
    // tray also mounts a full-screen invisible scrim that then swallows the
    // next drag on the wheel.

    /// HCD-01 — arriving on a room leaves the editor closed.
    ///
    /// C4 renamed the constant (`collapsedOnRoomChange = true` →
    /// `modeOnRoomChange = .decks`). Same rule, same assertion.
    func testLandingOnARoomDoesNotThrowTheEffectPanelOpen() {
        XCTAssertEqual(StudioMixerPresentation.modeOnRoomChange, .decks,
            "a room change must leave the region on the DECKS — an auto-opened tray covers the "
            + "wheel and its scrim eats the next scroll, which is the reported collision")
    }

    /// HCD-02 — the wheel survives landing on a streaming room.
    func testTheRoomWheelStaysMountedWhileTheTrayIsCollapsed() {
        XCTAssertFalse(
            StudioMixerPresentation.rolodexHidden(isEntertainmentRunning: true,
                                                  mixerVisible: false),
            "a streaming look with its tray closed must NOT remove the selector — that "
            + "deleted the wheel mid-gesture, destroying the very selection being made")

        XCTAssertFalse(
            StudioMixerPresentation.rolodexHidden(isEntertainmentRunning: false,
                                                  mixerVisible: true),
            "a non-streaming look's tray never hides the wheel either")
    }

    /// HCD-03 — the one case that legitimately hides it: a streaming look whose
    /// full-height tray is actually on screen.
    func testTheWheelIsHiddenOnlyWhenAStreamingTrayIsActuallyShowing() {
        XCTAssertTrue(
            StudioMixerPresentation.rolodexHidden(isEntertainmentRunning: true,
                                                  mixerVisible: true),
            "both conditions together are what reclaims the space")
    }

    // ── Track A / C4 — StudioRegionWiring extraction ──────────────────

    /// The room-change rule, in the new vocabulary. Arriving on a room returns
    /// the region to the DECKS — it never opens customization over the wheel.
    ///
    /// This is the same rule the old `collapsedOnRoomChange = true` carried;
    /// C4 renamed the state and moved the handler into `StudioRegionWiring`
    /// without changing behaviour, and this pins the direction so the rename
    /// cannot quietly invert it.
    func testRegionModeOnRoomChangeIsDecks() {
        XCTAssertEqual(StudioMixerPresentation.modeOnRoomChange, .decks,
            "landing on a room must return the region to the decks — opening "
            + "customization there is the selector collision that put a "
            + "full-screen scrim between the finger and the room wheel")

        // `.decks` is exactly the bit the old `isMixerCollapsed == true` meant,
        // and the two modes are distinct — a rename that collapsed them would
        // make the rule above unfalsifiable.
        XCTAssertNotEqual(StudioRegionMode.decks, .customization)
    }
}
