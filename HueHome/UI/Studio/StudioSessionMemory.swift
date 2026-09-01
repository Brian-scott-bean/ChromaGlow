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
