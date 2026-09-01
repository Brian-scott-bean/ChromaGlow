//
//  CustomizationIdentity.swift
//  HueHome
//
//  Unified Customization Engine — Slice 1 (Truth Foundation).
//
//  WHY THIS EXISTS
//  ───────────────
//  Before this file the app had two exact keys and no third:
//
//    • `RoomEffectKey`      (bridgeID, roomID)              — keys RUNNING EFFECTS.
//    • `StudioSelectionKey` (bridgeID, groupID, kind)       — keys the SELECTION.
//
//  Neither carries the running LOOK, the execution strategy, or a generation,
//  so nothing in the app could answer "is this pending write still addressed to
//  the thing the user was actually touching?". `RoomEffectKey` additionally
//  drops `kind`, so a room and a zone that share an id on one bridge collapse
//  into one key.
//
//  `RunningLookIdentity` is the missing third key. It is the unit the spec's
//  §19 running-identity contract is written against, and every fenced mutation
//  in Slice 1 captures one at gesture start and re-validates it at commit.
//
//  This file is deliberately PURE: no SwiftUI, no networking, no orchestrator,
//  no I/O. It is the piece the race tests can drive directly.
//

import Foundation

// ──────────────────────────────────────────────────────────────
// MARK: - Execution strategy (pure mirror of StudioStrategy)
// ──────────────────────────────────────────────────────────────

/// A `Hashable`, dependency-free mirror of `StudioStrategy`.
///
/// The identity has to be comparable inside pure tests that must not import
/// the Studio view model, and it has to survive being stored in a dictionary
/// key. Mirroring three cases is cheaper than making the whole Studio card
/// graph pure, and `init(strategy:)` keeps the two in lockstep at the one
/// boundary where they meet.
enum CustomizationExecution: Hashable, Sendable {
    /// Firmware effect running on the bridge (`effects_v2` or legacy).
    case bridgeNative(effect: String)
    /// App-driven engine loop owned by `UnifiedOrchestrator`.
    case appDriven(engineKey: String)
    /// Composer composition, identified by its preset.
    case composition(presetID: UUID)

    /// Stable, human-readable discriminator — used in audit strings and in
    /// `RunningLookIdentity.debugDescription`. Never parsed back.
    var kindLabel: String {
        switch self {
        case .bridgeNative: return "bridgeNative"
        case .appDriven:    return "appDriven"
        case .composition:  return "composition"
        }
    }

    /// True when the strategy is one the orchestrator drives frame-by-frame.
    /// Only these read a live param box, so only these can suffer a stale
    /// mid-flight param write.
    var isAppDriven: Bool {
        if case .appDriven = self { return true }
        return false
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Running look identity
// ──────────────────────────────────────────────────────────────

/// The exact identity of ONE running look on ONE target.
///
/// Six fields, and every one of them earns its place:
///
///  * `bridgeID`  — two bridges can expose the same Hue room id (round 4c).
///  * `groupID`   — the room or zone id on that bridge.
///  * `kind`      — a room and a zone may share an id; `RoomEffectKey` does
///                  not distinguish them, and this does.
///  * `cardID`    — which look is running, so a replacement is a new identity.
///  * `execution` — how it runs; a card that changes strategy is not the same
///                  running instance even under the same card id.
///  * `generation`— monotonic fence. Everything above can be identical across
///                  a stop/restart cycle; the generation is what makes a write
///                  issued before the stop recognizably stale after it.
///
/// Equality includes the generation. Use `addressesSameTarget(as:)` when you
/// mean "same place and same look, ignoring restarts".
struct RunningLookIdentity: Hashable, Sendable {
    let bridgeID: String?
    let groupID: String
    let kind: RoomDisplayItem.Kind
    let cardID: String
    let execution: CustomizationExecution
    let generation: CustomizationGeneration

    init(bridgeID: String?,
         groupID: String,
         kind: RoomDisplayItem.Kind,
         cardID: String,
         execution: CustomizationExecution,
         generation: CustomizationGeneration) {
        self.bridgeID = bridgeID
        self.groupID = groupID
        self.kind = kind
        self.cardID = cardID
        self.execution = execution
        self.generation = generation
    }

    // ── Bridges to the two keys that already exist ──────────────
    //
    // Slice 1 does NOT replace `RoomEffectKey` or `StudioSelectionKey`. It
    // composes with them, so existing call sites keep working and the new
    // identity can be threaded through incrementally.

    /// The existing selection key for this identity (read path).
    var selectionKey: StudioSelectionKey {
        StudioSelectionKey(bridgeID: bridgeID, groupID: groupID, kind: kind)
    }

    /// The existing running-effect key for this identity (write path).
    ///
    /// NOTE the deliberate lossiness: `RoomEffectKey` has no `kind`, so a room
    /// and a zone sharing an id on one bridge produce the SAME key here. That
    /// is a pre-existing property of `RoomEffectKey`, not something this type
    /// introduces — and it is exactly why `addressesSameTarget(as:)` compares
    /// `kind` itself instead of comparing effect keys.
    var effectKey: RoomEffectKey {
        RoomEffectKey(bridgeID: bridgeID, roomID: groupID)
    }

    /// Same physical target AND same look, ignoring the generation.
    ///
    /// This is the comparison for "is the user still pointed at the thing this
    /// gesture started on?" — a restart of the same look on the same room is
    /// still the same target, but it is NOT the same running instance, which
    /// is why the generation is compared separately by the fence.
    func addressesSameTarget(as other: RunningLookIdentity) -> Bool {
        bridgeID == other.bridgeID
            && groupID == other.groupID
            && kind == other.kind
            && cardID == other.cardID
            && execution == other.execution
    }

    /// Same physical place, whatever is running on it.
    func addressesSamePlace(as other: RunningLookIdentity) -> Bool {
        bridgeID == other.bridgeID && groupID == other.groupID && kind == other.kind
    }

    /// This identity minus the generation.
    ///
    /// Live values are stored under THIS key, not under the full identity. A
    /// generation bump means "in-flight writes are stale"; it must not mean
    /// "the room's live values vanished". Keying the value store by the target
    /// keeps a capability refresh or a transport change from silently
    /// resetting what the user can see on screen, while the fence still
    /// rejects the writes that were authored before the bump.
    var targetKey: RunningLookTargetKey {
        RunningLookTargetKey(bridgeID: bridgeID,
                             groupID: groupID,
                             kind: kind,
                             cardID: cardID,
                             execution: execution)
    }

    var debugDescription: String {
        "\(bridgeID ?? "legacy")|\(kind.rawValue)|\(groupID)|\(cardID)|\(execution.kindLabel)|g\(generation.value)"
    }
}

/// A `RunningLookIdentity` with the generation removed — "this look, on this
/// exact target", across restarts.
///
/// Note it keeps `kind`, which `RoomEffectKey` drops. Two targets that share a
/// bridge and an id but differ as room-vs-zone are two distinct keys here.
struct RunningLookTargetKey: Hashable, Sendable {
    let bridgeID: String?
    let groupID: String
    let kind: RoomDisplayItem.Kind
    let cardID: String
    let execution: CustomizationExecution
}

// ──────────────────────────────────────────────────────────────
// MARK: - Generation
// ──────────────────────────────────────────────────────────────

/// A monotonic counter that makes "this changed underneath you" observable.
///
/// Wrapped in a type rather than left as a bare `UInt64` so it cannot be
/// accidentally compared against an unrelated integer, and so the only way to
/// get a new one is `next()`.
struct CustomizationGeneration: Hashable, Sendable, Comparable {
    let value: UInt64

    init(_ value: UInt64) { self.value = value }

    static let initial = CustomizationGeneration(0)

    static func < (lhs: CustomizationGeneration, rhs: CustomizationGeneration) -> Bool {
        lhs.value < rhs.value
    }
}

/// Issues generations. One instance per Studio session.
///
/// `bump()` names the reason so the fence can report *why* a write was dropped
/// rather than only that it was. The reason list below is the vocabulary; what
/// is actually WIRED in production is narrower, and this comment lists both,
/// because an aspirational "every event bumps" sentence is exactly how a
/// missing seam hides in plain sight.
///
/// WIRED (a production path calls `bump` with this reason today):
///
///  * `.cardReplaced`      — `installRunningIdentity`, every `apply()` arm.
///  * `.stopped`           — `stopEffect` and `stopAll`.
///  * `.reset`             — `resetParams`.
///  * `.transportChanged`  — the composition Entertainment→REST failover, via
///                           `StudioRuntimeEvent.compositionFellBackToREST` →
///                           `rekeyRunningInstance(at:reason:)`. The Studio
///                           session-lost event removes the row outright
///                           instead (there is nothing left to rekey).
///
/// DELIBERATELY NOT WIRED, with the proof:
///
///  * `.bridgeReconnected` — an SSE reconnect changes no component of a
///    `RunningLookIdentity`: bridge id, group id, kind, card, execution and
///    generation are all app-side facts, and a re-registered client keeps the
///    same ip/token. The mutation authority for an app-driven look is the
///    bridge+room engine box, which SSE never touches. Availability is
///    re-resolved at render from the light cache, so a reconnect that changes
///    capability is already visible without a fence bump. Per-light SSE
///    patches arrive constantly; bumping on them would drop every drag the
///    user is in the middle of. A bridge genuinely going away is a different
///    event — `removeBridge` stops the rows first via
///    `stopEffectsForRemovedGroups`, which bumps `.stopped`.
///  * `.capabilityRefreshed` — same argument: a capability refresh re-reads
///    lights, and the resolver re-resolves from that cache at render. No
///    identity component moves, and no in-flight write becomes wrong.
///  * `.selectionChanged`  — the selection is not part of the identity by
///    design (that is the whole point of capturing identity at gesture start);
///    a selection move must not invalidate the OTHER target's pending writes.
///  * `.roomRemoved`       — reached as `.stopped` through the row teardown
///    above, so a second reason for the same event would double-bump.
@MainActor
final class CustomizationGenerationCounter {
    private(set) var current: CustomizationGeneration = .initial
    private(set) var lastReason: CustomizationInvalidationReason?

    init() {}

    @discardableResult
    func bump(_ reason: CustomizationInvalidationReason) -> CustomizationGeneration {
        current = CustomizationGeneration(current.value &+ 1)
        lastReason = reason
        return current
    }
}

/// Why a generation was invalidated. Every case here corresponds to a race the
/// audit (§24 / §28) requires Slice 1 to fence.
enum CustomizationInvalidationReason: String, Hashable, Sendable {
    case selectionChanged
    case cardReplaced
    case stopped
    case reset
    case capabilityRefreshed
    case transportChanged
    case bridgeReconnected
    case roomRemoved
}

// ──────────────────────────────────────────────────────────────
// MARK: - The fence
// ──────────────────────────────────────────────────────────────

/// The verdict on a write that was authored against a captured identity.
enum CustomizationFenceVerdict: Hashable, Sendable {
    /// The captured identity is still the live one — send it.
    case commit
    /// Drop it, with the reason a human (or a test) can assert on.
    case drop(CustomizationDropReason)

    var isCommit: Bool { if case .commit = self { return true }; return false }

    var dropReason: CustomizationDropReason? {
        if case .drop(let r) = self { return r }
        return nil
    }
}

enum CustomizationDropReason: String, Hashable, Sendable {
    /// Selection moved to a different bridge/room/zone.
    case targetChanged
    /// Same place, different look now running.
    case lookReplaced
    /// Same place and look, but a newer run — the captured one was stopped,
    /// reset, or otherwise superseded.
    case staleGeneration
    /// Nothing is running on that target at all any more.
    case nothingRunning
}

/// The one place that decides whether a captured write may still land.
///
/// Pure and static on purpose: every race test in `CustomizationIdentityTests`
/// drives this directly, with no orchestrator, no clock, and no sleeps.
enum CustomizationFence {

    /// - Parameters:
    ///   - captured: identity captured when the gesture/async work began.
    ///   - live:     identity of what is running on the target *now*, or nil
    ///               if nothing is.
    static func verdict(captured: RunningLookIdentity,
                        live: RunningLookIdentity?) -> CustomizationFenceVerdict {
        guard let live else { return .drop(.nothingRunning) }

        // Order matters. A write that is wrong about the PLACE is a
        // cross-target write — the most dangerous kind, and the one the spec
        // (§18.3) singles out — so it is diagnosed before anything else.
        guard captured.addressesSamePlace(as: live) else { return .drop(.targetChanged) }

        // Same place, different look: a replacement took the room while the
        // write was in flight.
        guard captured.cardID == live.cardID, captured.execution == live.execution else {
            return .drop(.lookReplaced)
        }

        // Same place, same look, older run: stop→restart, or a reset that
        // bumped the generation. The captured values describe a run that no
        // longer exists.
        guard captured.generation == live.generation else { return .drop(.staleGeneration) }

        return .commit
    }
}
