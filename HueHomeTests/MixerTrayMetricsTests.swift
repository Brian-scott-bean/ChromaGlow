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

// ─────────────────────────────────────────────────────────────────────────
// N1 — AI creation stays in place.
//
// The defect: `triggerAIGeneration` was the ONE creation path with no opener,
// and `apply`'s teardown nils `runningCardID` mid-flight, which the passive
// rule maps to `.decks` — so the generated result landed on the effects decks
// instead of the editor. The fix is an operation-token-identified editing-
// intent fence, and these tests exercise the exact pure rules the view
// consumes (`StudioAIGeneration`), including the transition SEQUENCE — a
// final-state-only assertion would miss an intermediate decks flash.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class StudioAIGenerationTests: XCTestCase {

    private let kitchenA = StudioSelectionKey(bridgeID: "bridge-A", groupID: "room-7", kind: .room)
    private let kitchenB = StudioSelectionKey(bridgeID: "bridge-B", groupID: "room-7", kind: .room)
    private let presetX = UUID()
    private let presetY = UUID()

    /// Replays `runningCardID` events through EXACTLY the two rules
    /// `StudioRegionWiring` composes, recording the mode after every event.
    private func replay(
        initial: StudioRegionMode,
        fence: AIEditingIntentFence?,
        selection: StudioSelectionKey?,
        events: [String?]
    ) -> [StudioRegionMode] {
        var mode = initial
        var trace: [StudioRegionMode] = []
        for event in events {
            if !StudioAIGeneration.passiveCloseSuppressed(
                fence: fence, currentSelection: selection, newRunningCardID: event) {
                mode = StudioMixerPresentation.modeAfterRunningCardChange(event, current: mode)
            }
            trace.append(mode)
        }
        return trace
    }

    // ── The transition-sequence regression ────────────────────────────

    /// An AI application over a running look emits teardown-nil then the new
    /// card id. With the fence up for the current selection, the region must
    /// never pass through `.decks` — not merely end elsewhere.
    func testAIApplicationEmitsNoIntermediateDecksMode() {
        let fence = AIEditingIntentFence(token: 1, target: kitchenA, presetID: presetX)
        let applicationEvents: [String?] = [nil, "comp_\(presetX.uuidString)"]

        // From an open editor: no step may be .decks at all.
        let fromEditor = replay(
            initial: .customization, fence: fence, selection: kitchenA,
            events: applicationEvents)
        XCTAssertFalse(fromEditor.contains(.decks),
            "the fenced application let an intermediate .decks through: \(fromEditor)")

        // From the decks (the AI hero's home): the teardown must not RE-assert
        // .decks after the result opens the editor — replaying the same events
        // after the deliberate open must keep it open.
        let afterOpen = replay(
            initial: StudioAIGeneration.modeAfterAIGeneration(applied: true, current: .decks),
            fence: fence, selection: kitchenA,
            events: applicationEvents)
        XCTAssertEqual(afterOpen, [.customization, .customization],
            "late-delivered application events knocked the opened editor back to the decks")
    }

    /// NEGATIVE CONTROL — with the fence down, the identical event replay MUST
    /// hit `.decks`. This proves the sequence assertion above can fail, and
    /// that the fence (not some other coincidence) is what carries the fix.
    func testWithoutTheFenceTheSameSequenceHitsDecks() {
        let trace = replay(
            initial: .customization, fence: nil, selection: kitchenA,
            events: [nil, "comp_\(presetX.uuidString)"])
        XCTAssertTrue(trace.contains(.decks),
            "the unfenced teardown no longer closes — the passive rule was weakened, "
            + "which is explicitly out of N1's authority")
    }

    // ── Fence scope: exactly the AI teardown, nothing else ────────────

    func testSuppressionIsExactlyScoped() {
        let fence = AIEditingIntentFence(token: 3, target: kitchenA, presetID: presetX)

        // Suppressed: the teardown nil, for the fenced selection.
        XCTAssertTrue(StudioAIGeneration.passiveCloseSuppressed(
            fence: fence, currentSelection: kitchenA, newRunningCardID: nil))

        // Not suppressed: no fence.
        XCTAssertFalse(StudioAIGeneration.passiveCloseSuppressed(
            fence: nil, currentSelection: kitchenA, newRunningCardID: nil))
        // Not suppressed: a non-nil change (the passive rule is a no-op there anyway).
        XCTAssertFalse(StudioAIGeneration.passiveCloseSuppressed(
            fence: fence, currentSelection: kitchenA, newRunningCardID: "any-card"))
        // Not suppressed: the user moved to another bridge's same-id room —
        // the fence is selection-EXACT, not room-id-keyed.
        XCTAssertFalse(StudioAIGeneration.passiveCloseSuppressed(
            fence: fence, currentSelection: kitchenB, newRunningCardID: nil))
        // Not suppressed: no selection at all.
        XCTAssertFalse(StudioAIGeneration.passiveCloseSuppressed(
            fence: fence, currentSelection: nil, newRunningCardID: nil))
    }

    // ── Overlapping operations: older finishes LAST ───────────────────

    /// Two AI operations on the SAME room; the older one completes after the
    /// newer one started. It must not apply its preset, must not move the
    /// region, and must not clear the newer operation's fence — a selection
    /// key alone could never make these distinctions, which is why the fence
    /// carries a token.
    func testOlderOperationFinishingLastIsInert() {
        let older = 1, newer = 2

        // The older completion may not proceed…
        XCTAssertEqual(
            StudioAIGeneration.completionAction(
                token: older, newestToken: newer,
                target: kitchenA, currentSelection: kitchenA),
            .supersededDoNothing,
            "an older AI operation acted after being superseded — same room, so "
            + "only the token can catch this")

        // …and may not lower the newer operation's fence.
        let newerFence = AIEditingIntentFence(token: newer, target: kitchenA, presetID: presetY)
        XCTAssertFalse(
            StudioAIGeneration.shouldClearFence(newerFence, completingToken: older),
            "the older operation cleared the newer operation's fence")
        // The newer operation itself still can.
        XCTAssertTrue(
            StudioAIGeneration.shouldClearFence(newerFence, completingToken: newer))
        // And with no fence standing there is nothing for anyone to clear.
        XCTAssertFalse(StudioAIGeneration.shouldClearFence(nil, completingToken: newer))

        // Same room + same token but a different generated preset is a
        // DIFFERENT fence: preset identity is part of the fence, per N1.
        XCTAssertNotEqual(
            AIEditingIntentFence(token: newer, target: kitchenA, presetID: presetX),
            newerFence)
    }

    /// A transport-prompt response can arrive arbitrarily late. After the
    /// selection moved — including to another bridge's room with the SAME room
    /// id — it must apply nothing and open nothing.
    func testStalePromptResponseAfterSelectionChangeAppliesNothing() {
        XCTAssertEqual(
            StudioAIGeneration.completionAction(
                token: 2, newestToken: 2,
                target: kitchenA, currentSelection: kitchenB),
            .staleSelectionDoNothing)
        XCTAssertEqual(
            StudioAIGeneration.completionAction(
                token: 2, newestToken: 2,
                target: kitchenA, currentSelection: nil),
            .staleSelectionDoNothing)
        // The happy path still proceeds — the guards must not be over-broad.
        XCTAssertEqual(
            StudioAIGeneration.completionAction(
                token: 2, newestToken: 2,
                target: kitchenA, currentSelection: kitchenA),
            .proceed)
    }

    // ── The deliberate-open rule ──────────────────────────────────────

    /// Same shape and same direction as `modeAfterNewCompositionCreated`: an
    /// APPLIED result opens the editor from anywhere; anything less leaves the
    /// region exactly where it was (refusals present their own surfaces).
    func testAIGenerationOpensOnlyOnAnAppliedResult() {
        for current in [StudioRegionMode.decks, .customization] {
            XCTAssertEqual(
                StudioAIGeneration.modeAfterAIGeneration(applied: true, current: current),
                .customization,
                "an applied AI result must open the editor (from \(current))")
            XCTAssertEqual(
                StudioAIGeneration.modeAfterAIGeneration(applied: false, current: current),
                current,
                "a refused AI application moved the region (from \(current))")
        }
    }

    /// The typed outcome carries the three identities N1 requires: the exact
    /// captured selection, the generated preset's id, and a typed disposition.
    /// (Compile-time shape pin — if a field is renamed or dropped, this stops
    /// building rather than silently narrowing the contract.)
    func testAIOutcomeCarriesTargetPresetAndDisposition() {
        let outcome = StudioViewModel.AIGenerationApplication(
            target: kitchenA, presetID: presetX, disposition: .staleSelection)
        XCTAssertEqual(outcome.target, kitchenA)
        XCTAssertEqual(outcome.presetID, presetX)
        XCTAssertEqual(outcome.disposition, .staleSelection)
        XCTAssertNotEqual(
            StudioViewModel.AIGenerationApplication.Disposition.applied, .refused)
    }
}
