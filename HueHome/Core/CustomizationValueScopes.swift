//
//  CustomizationValueScopes.swift
//  HueHome
//
//  Unified Customization Engine — Slice 1 (Truth Foundation).
//
//  THE DEFECT THIS FIXES
//  ─────────────────────
//  Today `StudioViewModel` holds:
//
//      var paramValues: [String: [String: Double]] = [:]   // [cardID: [paramID: value]]
//      var paramColors: [String: [String: Color]]  = [:]
//
//  keyed by CARD ID and nothing else, and the orchestrator holds one live box
//  per BRIDGE (`studioEngineRuntimesByBridge[bridgeID]?.paramBox`). Between
//  them those two dictionaries are serving three different jobs at once:
//  persisted last-used defaults, live running-instance values, and the value
//  the user is mid-drag on. Spec §18 requires all three to be separate, and
//  audit §16 requires the live one to be keyed to exact running identity.
//
//  The consequences on current `main` are concrete, not theoretical:
//
//    • Party on Bridge A at speed 20 and Party on Bridge B at speed 80 cannot
//      both exist — `paramValues["party"]` is one dictionary. Selecting either
//      room shows whichever was edited last.
//    • `setParamValue` routes the live push by `currentRoomEffect?.room.bridgeID`
//      read at call time, and `updateStudioParams` guards on `bridgeID` ALONE.
//      A write authored on room A can therefore land on room B's engine after
//      the selection moves, provided both rooms are on one bridge.
//    • `resetParams` nils `paramValues[card.id]` card-globally, so resetting on
//      one bridge blanks the other bridge's displayed values too.
//
//  This type separates the three scopes and makes every commit pass the fence.
//
//  Generic over the colour type so the pure layer stays free of SwiftUI; the
//  app instantiates it with `Color`, tests with anything `Hashable`.
//

import Foundation

// ──────────────────────────────────────────────────────────────
// MARK: - A value set
// ──────────────────────────────────────────────────────────────

/// Numbers and colours for one card, in one scope.
struct CustomizationValueSet<ColorValue: Hashable & Sendable>: Hashable, Sendable {
    var numbers: [String: Double]
    var colors: [String: ColorValue]

    init(numbers: [String: Double] = [:], colors: [String: ColorValue] = [:]) {
        self.numbers = numbers
        self.colors = colors
    }

    var isEmpty: Bool { numbers.isEmpty && colors.isEmpty }

    /// `self` layered over `base` — used to resolve a running instance's live
    /// values against the card's persisted defaults.
    func layered(over base: CustomizationValueSet<ColorValue>) -> CustomizationValueSet<ColorValue> {
        var merged = base
        merged.numbers.merge(numbers) { _, mine in mine }
        merged.colors.merge(colors) { _, mine in mine }
        return merged
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Draft
// ──────────────────────────────────────────────────────────────

/// The value a gesture is currently producing, and the identity it was
/// captured against.
///
/// Exactly one draft exists at a time: a finger is on one control. Holding the
/// identity here — captured at gesture START — is what lets `commit` refuse a
/// write whose target moved mid-drag (spec §18.3).
struct CustomizationDraft<ColorValue: Hashable & Sendable>: Hashable, Sendable {
    let identity: RunningLookIdentity
    let control: CustomizationControlID
    var number: Double?
    var color: ColorValue?
}

/// What happened when a draft, or any captured write, was committed.
enum CustomizationCommitResult<ColorValue: Hashable & Sendable>: Hashable, Sendable {
    /// Landed. Carries the resolved live value set for the target.
    case committed(RunningLookIdentity, CustomizationValueSet<ColorValue>)
    /// Refused by the fence, with the reason.
    case dropped(CustomizationDropReason)

    var didCommit: Bool { if case .committed = self { return true }; return false }

    var dropReason: CustomizationDropReason? {
        if case .dropped(let r) = self { return r }
        return nil
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - The three scopes
// ──────────────────────────────────────────────────────────────

/// Persisted defaults, live running-instance values, and the in-flight draft —
/// kept apart, with every crossing between them fenced.
@MainActor
final class CustomizationValueScopes<ColorValue: Hashable & Sendable> {

    /// SCOPE 1 — "what should this card use next time I start it?"
    /// Keyed by card id, matching today's `StudioParamStore` contract.
    private var persistedDefaults: [String: CustomizationValueSet<ColorValue>] = [:]

    /// SCOPE 2 — "what is this exact bridge + room/zone + look using now?"
    /// Keyed by target, so the same card on two bridges is two entries. The
    /// generation is stored beside the values rather than inside the key, so a
    /// capability refresh does not wipe what the user is looking at.
    private var runningValues: [RunningLookTargetKey: CustomizationValueSet<ColorValue>] = [:]
    private var runningGenerations: [RunningLookTargetKey: CustomizationGeneration] = [:]

    /// SCOPE 2's FLOOR — the card's persisted defaults FROZEN at the instant
    /// this instance started, one snapshot per running target.
    ///
    /// THE LEAK THIS CLOSES, and why it is a frozen base rather than a
    /// complete seed. `live(for:)` layers an instance's own values over a
    /// base, and scope 1 tracks LAST-USED values — so when the base was read
    /// live, a param this instance had never written resolved against whatever
    /// ANOTHER instance had since pushed into the defaults. Two rooms running
    /// one card, edit room A's speed, and room B's live speed moved with it.
    ///
    /// Materializing every catalog parameter into `runningValues` at start
    /// would also close it, but at a price that is worse than the leak: the
    /// running set is what `seedApplyCurrentLook` and the Preview Live restore
    /// copy into the card's PERSISTED defaults, so a complete set writes a
    /// value for every control the user never touched — and the apply-time
    /// sentinel "a stored warmth default exists ⇒ the user set it" becomes
    /// permanently true, shipping a mirek with every bridge-native start.
    ///
    /// Freezing the base keeps the running set SPARSE (it holds exactly what
    /// this instance was given) while still answering for every control from
    /// the first frame, out of a base that later default writes cannot move.
    private var frozenBases: [RunningLookTargetKey: CustomizationValueSet<ColorValue>] = [:]

    /// SCOPE 3 — "what is the finger doing right now?"
    private(set) var draft: CustomizationDraft<ColorValue>?

    init() {}

    // ── Scope 1: persisted defaults ─────────────────────────────

    func defaults(forCard cardID: String) -> CustomizationValueSet<ColorValue> {
        persistedDefaults[cardID] ?? CustomizationValueSet()
    }

    func setDefaults(_ set: CustomizationValueSet<ColorValue>, forCard cardID: String) {
        persistedDefaults[cardID] = set
    }

    /// Factory-reset one card's persisted defaults. Deliberately does NOT touch
    /// any running instance — that is `reset(_:)`'s job, and conflating the two
    /// is the current `resetParams` bug.
    func clearDefaults(forCard cardID: String) {
        persistedDefaults[cardID] = nil
    }

    // ── Scope 2: live running-instance values ───────────────────

    /// Register a look as running: an EMPTY own-value set, over a base frozen
    /// from the card's persisted defaults as they are at this instant.
    ///
    /// Sparse by design — see `frozenBases`. The instance owns only what is
    /// written to it, and everything else reads out of a snapshot that a later
    /// default write (another instance's edit, an Apply Current Look, a
    /// Preview Live restore) cannot move underneath it.
    func startRunning(_ identity: RunningLookIdentity) {
        let key = identity.targetKey
        runningValues[key] = CustomizationValueSet()
        frozenBases[key] = defaults(forCard: identity.cardID)
        runningGenerations[key] = identity.generation
    }

    /// Live values for an exact running instance: its own writes layered over
    /// the base frozen at start, so a param it never touched still answers —
    /// with the value the card had when this run began, never with one another
    /// instance has since written into the shared defaults.
    ///
    /// An identity that is NOT running has no frozen base, and falls back to
    /// the card's current defaults: nothing is running, so there is no run for
    /// a snapshot to describe.
    func live(for identity: RunningLookIdentity) -> CustomizationValueSet<ColorValue> {
        let base = frozenBases[identity.targetKey] ?? defaults(forCard: identity.cardID)
        guard let own = runningValues[identity.targetKey] else { return base }
        return own.layered(over: base)
    }

    /// Is this identity the current run of its target?
    func isCurrent(_ identity: RunningLookIdentity) -> Bool {
        runningGenerations[identity.targetKey] == identity.generation
    }

    /// The live identity for a target, if one is running.
    func liveIdentity(for identity: RunningLookIdentity) -> RunningLookIdentity? {
        guard let generation = runningGenerations[identity.targetKey] else { return nil }
        return RunningLookIdentity(bridgeID: identity.bridgeID,
                                   groupID: identity.groupID,
                                   kind: identity.kind,
                                   cardID: identity.cardID,
                                   execution: identity.execution,
                                   generation: generation)
    }

    /// Advance a running instance to a new generation WITHOUT disturbing its
    /// live values.
    ///
    /// This is the capability-refresh / transport-change / reconnect path. The
    /// world changed enough that writes authored before now are untrustworthy,
    /// but the look never stopped and the user is still looking at its real
    /// values — reseeding from defaults here would blank the screen for a
    /// reason the user cannot see. The frozen base is kept for the same
    /// reason: the run did not restart, so its floor did not move.
    @discardableResult
    func rekey(_ identity: RunningLookIdentity,
               to newGeneration: CustomizationGeneration) -> RunningLookIdentity? {
        let key = identity.targetKey
        guard runningGenerations[key] != nil else { return nil }
        runningGenerations[key] = newGeneration
        // A draft captured under the old generation can no longer commit; drop
        // it rather than let it land against a run it does not describe.
        if draft?.identity.targetKey == key { draft = nil }
        return RunningLookIdentity(bridgeID: identity.bridgeID,
                                   groupID: identity.groupID,
                                   kind: identity.kind,
                                   cardID: identity.cardID,
                                   execution: identity.execution,
                                   generation: newGeneration)
    }

    /// Stop: forget the live values and the generation. A pending write for
    /// this target now fences as `.nothingRunning`.
    func stopRunning(_ identity: RunningLookIdentity) {
        runningValues[identity.targetKey] = nil
        runningGenerations[identity.targetKey] = nil
        frozenBases[identity.targetKey] = nil
        if draft?.identity.targetKey == identity.targetKey { draft = nil }
    }

    /// Stop every scope registered at ONE PHYSICAL PLACE, whatever card or
    /// execution it names, and report which target keys were retired.
    ///
    /// The belt for the apply race (R4B). Serialization is the braces: one
    /// lifecycle body runs at a time, so two applies cannot interleave their
    /// installs. But a scope is keyed by `RunningLookTargetKey`, which carries
    /// the CARD and the EXECUTION — so any path that installs a new look on a
    /// place without routing through `stopEffect` first (a saved-look outcome,
    /// a handoff replay, a strategy change under one card id) would leave the
    /// predecessor's scope behind, `isCurrent`, with its pending sends still
    /// passing the fence. `installRunningIdentity` calls this immediately
    /// before `startRunning`, so a place can never hold two live scopes.
    ///
    /// Returns the retired keys so the caller can cancel exactly their pending
    /// bridge sends — this type owns values, never tasks.
    @discardableResult
    func stopRunning(atPlace bridgeID: String?,
                     groupID: String,
                     kind: RoomDisplayItem.Kind) -> [RunningLookTargetKey] {
        let matches = Set(runningValues.keys).union(runningGenerations.keys).filter {
            $0.bridgeID == bridgeID && $0.groupID == groupID && $0.kind == kind
        }
        guard !matches.isEmpty else { return [] }
        for key in matches {
            runningValues[key] = nil
            runningGenerations[key] = nil
            frozenBases[key] = nil
        }
        if let draft, matches.contains(draft.identity.targetKey) { self.draft = nil }
        return Array(matches)
    }

    /// Stop everything (Stop All).
    func stopAll() {
        runningValues.removeAll()
        runningGenerations.removeAll()
        frozenBases.removeAll()
        draft = nil
    }

    /// Reset ONE running instance to its card defaults, under a new
    /// generation so older in-flight writes lose the fence.
    ///
    /// Contrast with today's `resetParams`, which nils the card-global dict and
    /// therefore resets every bridge at once.
    ///
    /// The own-value set is EMPTIED and the base RE-FROZEN from the defaults as
    /// they are now — which, on the production reset path, is immediately after
    /// `clearDefaults`, so reads fall through to the catalog. Writing
    /// `defaults(forCard:)` into the running set instead is what left a reset
    /// instance tracking the shared dictionary again: the very leak reset was
    /// supposed to end, re-opened by the reset itself.
    @discardableResult
    func reset(_ identity: RunningLookIdentity,
               newGeneration: CustomizationGeneration) -> RunningLookIdentity {
        let key = identity.targetKey
        runningValues[key] = CustomizationValueSet()
        frozenBases[key] = defaults(forCard: identity.cardID)
        runningGenerations[key] = newGeneration
        if draft?.identity.targetKey == key { draft = nil }
        return RunningLookIdentity(bridgeID: identity.bridgeID,
                                   groupID: identity.groupID,
                                   kind: identity.kind,
                                   cardID: identity.cardID,
                                   execution: identity.execution,
                                   generation: newGeneration)
    }

    // ── Scope 3: draft ──────────────────────────────────────────

    /// Begin a gesture. The identity captured here is the one the eventual
    /// commit is measured against, no matter what the selection does meanwhile.
    func beginDraft(control: CustomizationControlID, on identity: RunningLookIdentity) {
        draft = CustomizationDraft(identity: identity, control: control,
                                   number: nil, color: nil)
    }

    func updateDraft(number: Double) {
        draft?.number = number
    }

    func updateDraft(color: ColorValue) {
        draft?.color = color
    }

    func cancelDraft() {
        draft = nil
    }

    /// Commit the in-flight draft against the world as it is NOW.
    ///
    /// This is the fenced crossing from scope 3 to scope 2. It is the only way
    /// a draft becomes a live value, and it consumes the draft either way.
    @discardableResult
    func commitDraft() -> CustomizationCommitResult<ColorValue> {
        guard let pending = draft else { return .dropped(.nothingRunning) }
        draft = nil
        return commit(captured: pending.identity,
                      control: pending.control,
                      number: pending.number,
                      color: pending.color)
    }

    /// Commit a captured write that did not come from a live gesture — a
    /// debounced send, a delayed reapply, anything that can land late.
    @discardableResult
    func commit(captured: RunningLookIdentity,
                control: CustomizationControlID,
                number: Double? = nil,
                color: ColorValue? = nil) -> CustomizationCommitResult<ColorValue> {

        let verdict = CustomizationFence.verdict(captured: captured,
                                                 live: liveIdentity(for: captured))
        guard verdict.isCommit else {
            return .dropped(verdict.dropReason ?? .nothingRunning)
        }

        // A write must name a control that belongs to the card it was authored
        // against. This is cheap, and it makes a mis-routed control id fail
        // loudly here instead of writing a nonsense key into the live box.
        guard control.cardID == captured.cardID else {
            return .dropped(.lookReplaced)
        }

        let key = captured.targetKey
        // Sparse: a commit adds ONE field to what this instance owns. Seeding
        // from the card's defaults here would smuggle the whole shared
        // dictionary into the running set — and from there into the persisted
        // defaults, via every path that copies a live set back out.
        var set = runningValues[key] ?? CustomizationValueSet()
        if let number { set.numbers[control.paramID] = number }
        if let color { set.colors[control.paramID] = color }
        runningValues[key] = set

        let base = frozenBases[key] ?? defaults(forCard: captured.cardID)
        return .committed(captured, set.layered(over: base))
    }

    // ── Introspection (tests, and the matrix generator) ─────────

    var runningTargetCount: Int { runningValues.count }

    var runningTargets: [RunningLookTargetKey] {
        runningValues.keys.sorted {
            ($0.bridgeID ?? "", $0.groupID, $0.kind.rawValue, $0.cardID)
                < ($1.bridgeID ?? "", $1.groupID, $1.kind.rawValue, $1.cardID)
        }
    }
}
