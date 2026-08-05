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
        XCTAssertGreaterThanOrEqual(MixerTrayMetrics.backToDecksRowHeight, 36)
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

    /// HCD-02/03, superseded by Track A C5 — `rolodexHidden` is DELETED.
    ///
    /// The old pair tested WHEN the wheel could be unmounted. Inline, the
    /// customization region never covers the wheel, so the answer is "never"
    /// and the predicate that had to stay correct is gone. Regressing this
    /// costs a constant and the render probe in StudioScrollStabilityTests.
    func testRolodexIsAlwaysMounted() {
        XCTAssertTrue(StudioMixerPresentation.rolodexAlwaysMounted,
            "the wheel must be unconditionally mounted — keying its removal on a "
            + "running streaming look deleted it MID-GESTURE, destroying the very "
            + "selection being made, and any predicate here can regress that way again")
    }

    /// Build 46's fix, explicitly named and still standing after C5 replaced
    /// the overlay with an inline region. `bottomClearance` is the one height
    /// helper that did NOT die with the fixed-height tray.
    func testBottomClearanceStillAvoidsTheDoubleCount() {
        // Bar mounted: its safeAreaInset has already floored the content and
        // cleared the floating tab bar, so only a card-to-card gap is owed.
        // Re-adding tabBarClearance here is the ~200pt dead band.
        XCTAssertEqual(
            MixerTrayMetrics.bottomClearance(bottomInset: musicBarInset, barMounted: true),
            HueSpacing.sm,
            "the double-count is back — the region would sit on a floor it is already on")
        XCTAssertLessThan(
            MixerTrayMetrics.bottomClearance(bottomInset: musicBarInset, barMounted: true),
            MixerTrayMetrics.tabBarClearance(bottomInset: musicBarInset))

        // Bar suppressed: nothing else clears the tab bar, so the full figure
        // is owed and compact geometry is unchanged.
        XCTAssertEqual(
            MixerTrayMetrics.bottomClearance(bottomInset: musicBarInset, barMounted: false),
            MixerTrayMetrics.tabBarClearance(bottomInset: musicBarInset))
    }

    // ── Track A / C5 — passive vs deliberate ──────────────────────────

    /// A passive runtime change may CLOSE customization but must never OPEN it.
    ///
    /// `runningCardID` goes nil for reasons the user never asked for — a stop
    /// completing, a recovered animation reconciling, an external teardown. The
    /// pre-C5 handler set `.customization` there, which is the "panel appeared
    /// over the wheel on its own" class this track exists to end.
    func testPassiveRunningCardChangeNeverOpensCustomization() {
        for current in [StudioRegionMode.decks, .customization] {
            // Teardown → decks, from either mode.
            XCTAssertEqual(
                StudioMixerPresentation.modeAfterRunningCardChange(nil, current: current),
                .decks,
                "an effect ending must return to the decks (from \(current))")

            // A card merely BECOMING the running card — recovery, reconciliation,
            // an external start — must leave the mode exactly as it was.
            XCTAssertEqual(
                StudioMixerPresentation.modeAfterRunningCardChange("some-card", current: current),
                current,
                "a passive runtime change moved the region (from \(current))")
        }

        // Specifically: never .customization from .decks, for ANY input.
        for newValue in [nil, "candle-card", ""] as [String?] {
            XCTAssertNotEqual(
                StudioMixerPresentation.modeAfterRunningCardChange(newValue, current: .decks),
                .customization,
                "a passive change opened customization for newValue=\(String(describing: newValue))")
        }
    }

    /// …while a deliberate activation is exactly what does open it.
    func testDeliberateActivationOpensCustomization() {
        XCTAssertEqual(StudioMixerPresentation.modeOnDeliberateActivation, .customization,
            "tapping a card to start it, the Live Controls pill, and the rolodex's "
            + "onActivate all route through this — if it stops opening customization "
            + "there is no way left to reach the editor")
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

    // ── Build-47 device finding 2 — creating a NEW composition ────────
    //
    // "+ Create" is deliberate editing intent and should land the user IN the
    // editor. Before this it called the view model and discarded the result, so
    // the host appeared only when `regionMode` happened to still be
    // `.customization` — and after any room scrub or prior teardown the wiring
    // has already set it to `.decks`.

    func testSuccessfulNewCompositionCreationOpensCustomization() {
        for current in [StudioRegionMode.decks, .customization] {
            XCTAssertEqual(
                StudioMixerPresentation.modeAfterNewCompositionCreated(
                    created: true, current: current),
                .customization,
                "creating a new composition must open the editor (from \(current))")
        }
    }

    /// A refused room, a cancelled transport prompt, a failed start, or a
    /// re-entry on an already-running starter card are all NOT creation.
    func testFailedOrCancelledCreationLeavesTheRegionAlone() {
        for current in [StudioRegionMode.decks, .customization] {
            XCTAssertEqual(
                StudioMixerPresentation.modeAfterNewCompositionCreated(
                    created: false, current: current),
                current,
                "a failed or cancelled creation moved the region (from \(current))")
        }
    }

    /// The two rules point in OPPOSITE directions and must never be swapped: a
    /// creation result opens, a passive runtime change can only close. Wiring the
    /// creation rule to `runningCardID` would reintroduce the exact defect C5
    /// removed, because that fires for teardowns and recoveries too.
    func testNewCompositionRuleIsDistinctFromThePassiveRunningCardRule() {
        XCTAssertEqual(
            StudioMixerPresentation.modeAfterNewCompositionCreated(
                created: true, current: .decks),
            .customization)
        XCTAssertNotEqual(
            StudioMixerPresentation.modeAfterRunningCardChange("composer_starter", current: .decks),
            .customization,
            "a card merely becoming the running card must NOT open customization — "
            + "only a creation RESULT may")
    }
}
