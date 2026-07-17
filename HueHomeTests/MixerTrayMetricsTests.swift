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
