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
}
