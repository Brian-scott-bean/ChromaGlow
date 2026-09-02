//
//  CustomizationPreview.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (Preview Live, spec §16.5).
//
//  Preview Live auditions a look on the EXACT selected target while
//  preserving the previous running look and its exact live values. Cancel
//  restores the previous look exactly; apply commits the new one. The
//  restore is fenced: a target change, a stop, a card replacement, or a
//  generation bump between audition and cancel makes the restore DROP
//  instead of landing on whatever runs there now — the Round-4f
//  "revalidate at the moment of teardown" discipline.
//
//  This machine holds ONLY the snapshot and the fencing state. Audition,
//  restore, and commit all execute through the authoritative production
//  paths (`apply()` seeded via `CustomizationValueScopes`) — there is no
//  second runtime ownership system here.
//
//  Generic over the colour type so the pure layer stays free of SwiftUI —
//  same convention as `CustomizationValueScopes`.
//

import Foundation

/// What Preview Live must remember to put the world back exactly.
struct PreviewLiveSnapshot<ColorValue: Hashable & Sendable>: Hashable, Sendable {
    /// The look that was running before the audition (nil values = the
    /// target was idle; cancel then stops the preview and restores nothing).
    let previous: RunningLookIdentity?
    /// The previous instance's exact live values at snapshot time.
    let previousValues: CustomizationValueSet<ColorValue>?
    /// Whether the previous look was streaming (transport restore hint).
    let previousWasStreaming: Bool
}

enum PreviewLiveVerdict<ColorValue: Hashable & Sendable>: Hashable, Sendable {
    /// Restore the snapshot through the normal apply path.
    case restore(PreviewLiveSnapshot<ColorValue>)
    /// The world moved on — do not touch what runs there now.
    case drop(CustomizationDropReason)
}

/// The audition lifecycle: idle → snapshotted → previewing → done.
@MainActor
final class PreviewLiveMachine<ColorValue: Hashable & Sendable> {

    private(set) var snapshot: PreviewLiveSnapshot<ColorValue>?
    /// The identity of the AUDITIONED look once it started — the fence the
    /// cancel-restore is measured against.
    private(set) var previewIdentity: RunningLookIdentity?

    init() {}

    var isPreviewing: Bool { snapshot != nil }

    /// Capture the world before the audition starts.
    func begin(previous: RunningLookIdentity?,
               previousValues: CustomizationValueSet<ColorValue>?,
               previousWasStreaming: Bool) -> PreviewLiveSnapshot<ColorValue> {
        let snap = PreviewLiveSnapshot(previous: previous,
                                       previousValues: previousValues,
                                       previousWasStreaming: previousWasStreaming)
        snapshot = snap
        previewIdentity = nil
        return snap
    }

    /// The audition started — this exact instance is what cancel may undo.
    func previewStarted(_ identity: RunningLookIdentity) {
        guard snapshot != nil else { return }
        previewIdentity = identity
    }

    /// Cancel. The verdict is fenced on the CURRENT live identity of the
    /// preview's target: only if the auditioned instance is still the one
    /// running there may the previous look be restored. Consumes the state
    /// either way — a preview never outlives its answer.
    func cancelVerdict(live: RunningLookIdentity?) -> PreviewLiveVerdict<ColorValue> {
        defer { snapshot = nil; previewIdentity = nil }
        guard let snap = snapshot else { return .drop(.nothingRunning) }
        guard let previewIdentity else {
            // Snapshot taken but the audition never started — nothing was
            // changed, so there is nothing to restore.
            return .drop(.nothingRunning)
        }
        let verdict = CustomizationFence.verdict(captured: previewIdentity, live: live)
        guard verdict.isCommit else {
            return .drop(verdict.dropReason ?? .nothingRunning)
        }
        return .restore(snap)
    }

    /// Apply — the auditioned look is the keeper. The snapshot is discarded;
    /// nothing is restored, ever.
    func commit() {
        snapshot = nil
        previewIdentity = nil
    }
}
