// StudioSessionMemory.swift
// CastChroma — Slice 2 per-target working memory (spec §14.4).
//
// Each ACTIVE target remembers its own meaningful editing state during the
// current session: which color editor is expanded, whether the identity
// panel is open, the board's last scroll anchor. Switching between active
// targets restores each one's working state; stopping a target clears its
// memory; when the overall session ends (the active set empties) everything
// clears so a future session starts clean.
//
// Deliberately NEVER persisted — this is session working state, not
// preferences (spec §14.4 "temporary editing expansions reset").

import SwiftUI

/// One target's transient editing state.
struct TargetWorkingState: Equatable {
    /// The board scroll anchor to restore (a control/section id).
    var scrollAnchorID: String? = nil
    /// The color control whose inline editor is expanded, if any.
    var expandedColorControlID: CustomizationControlID? = nil
    /// Whether the identity header's operational panel is open.
    var identityPanelOpen: Bool = false
    /// The Composer layer this target is editing (plan §24 "current domain").
    /// Per target, so two rooms running compositions keep their own layer;
    /// a stopped target's selection dies with its memory.
    var activeCompositionTab: CompositionLayerTab = .palette
    /// The harmony rule the Composer's chip row shows for this target
    /// (review round, A-1/A-2). Per target: seeded from the running preset's
    /// saved rule at apply and at Revert, changed only by the user's chip tap
    /// through `StudioViewModel.setHarmonyRule` (which rewrites the palette
    /// through the edit fence) — so room A's lit chip can never feed room B's
    /// pad, and a programmatic clear (album colours) never fires the
    /// destructive palette echo.
    var activeHarmonyRule: HarmonyRule = .none
}

@MainActor
@Observable
final class StudioSessionWorkingMemory {

    private var states: [RunningLookTargetKey: TargetWorkingState] = [:]

    func state(for target: RunningLookTargetKey) -> TargetWorkingState {
        states[target] ?? TargetWorkingState()
    }

    func update(_ target: RunningLookTargetKey,
                _ mutate: (inout TargetWorkingState) -> Void) {
        var state = states[target] ?? TargetWorkingState()
        mutate(&state)
        states[target] = state
    }

    /// Binding into one field of a target's state — what the board and
    /// header views hold onto.
    func binding<Value: Equatable>(
        for target: RunningLookTargetKey,
        _ keyPath: WritableKeyPath<TargetWorkingState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.state(for: target)[keyPath: keyPath] },
            set: { newValue in self.update(target) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// The target stopped — its expansions die with it.
    func clear(for target: RunningLookTargetKey) {
        states[target] = nil
    }

    /// The overall session ended — a future session starts clean.
    func clearAll() {
        states.removeAll()
    }

    var isEmpty: Bool { states.isEmpty }
}
