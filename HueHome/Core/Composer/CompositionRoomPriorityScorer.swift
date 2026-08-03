import Foundation

enum CompositionRoomPriorityScorer {
    struct Input {
        let nextDueAt: CFAbsoluteTime
        let isColorPadInteracting: Bool
        let interactionBurstUntil: CFAbsoluteTime?
        let pendingSettle: Bool
        let lastSentAt: CFAbsoluteTime?
        let startTime: CFAbsoluteTime
        let sendCount: Int
    }

    static func score(
        now: CFAbsoluteTime,
        input: Input
    ) -> Double? {
        if now + 0.004 < input.nextDueAt { return nil }

        let burstActive = input.interactionBurstUntil.map { now < $0 } ?? false
        let overdue = max(0, now - input.nextDueAt)
        let sinceLastSend = now - (input.lastSentAt ?? input.startTime)

        var score = 0.0
        if input.isColorPadInteracting { score += 1000 }
        if burstActive { score += 500 }
        if input.pendingSettle { score += 260 }
        score += min(220, overdue * 120)
        score += min(160, max(0, sinceLastSend - 1.4) * 45)
        score -= min(60, Double(input.sendCount % 120) * 0.35)
        return score
    }
}

// MARK: - CompositionSendLedger (Composer 2 packet 4)

/// Truthful bookkeeping for Composer REST sends, replacing the enqueue-time
/// telemetry that structurally reported zero lag and counted discarded work as
/// sent.
///
/// PURE VALUE TYPE, exactly like the scorer above: no internal clock (every
/// timestamp is a parameter), no knowledge of publication
/// (`activeRESTCadenceByBridgeRoom` belongs to the orchestrator), no knowledge
/// of `RestSender` beyond the fact that the orchestrator only reports what the
/// sender PROVED — `replacedPending`, `clear`'s removal result — never what it
/// inferred. `flush()` dequeues before dispatch, so "enqueued but not started"
/// is not evidence of anything; the state machine below therefore trusts only
/// explicit event reports and discards everything that does not fit.
///
/// SESSION MODEL — one session per (bridgeKey, scope), carrying the ACTIVE
/// generation. `beginSession` always starts from a blank slate, even for a
/// repeated generation value; `deactivateSession` is its lifecycle mirror, not
/// a sixth telemetry event. Events are admitted by TWO gates, both required:
///   1. the token's generation must be the session's active generation;
///   2. the token must be RETAINED and in the right state for the transition
///      (enqueued → started → completed; cancelled from enqueued OR started;
///      superseded from enqueued only).
/// Gate 2 is what makes a same-generation `beginSession` safe: a pre-reset
/// token passes gate 1 by numeric accident, but its state was wiped, so every
/// report it makes is ignored. Duplicate and out-of-order terminals die the
/// same way — the first terminal removes the token, exactly once.
struct CompositionSendLedger {

    /// Identity of one unit of Composer REST work, minted by the orchestrator
    /// at enqueue time. DO NOT change this shape (packet 4 contract).
    struct Token: Hashable, Sendable {
        /// `preservedBridgeID ?? "legacy"` — the SAME normalization
        /// `restSender(for:)` applies, so token identity can never disagree
        /// with the mailbox that holds the work (see the packet 4
        /// bridge-identity correction).
        let bridgeKey: String
        let scope: RestScope
        /// `CompositionRuntime.generation` at mint time. A `let` on the
        /// runtime, so tokens created before a transport transition keep the
        /// OLD generation and are rejected by the new session.
        let generation: Int
        let sequence: UInt64
    }

    /// Aggregates for one session, computed against a caller-supplied `asOf`.
    /// An inactive (never-begun or deactivated) session yields the empty
    /// snapshot: zero counters, nil averages, nil cadence.
    struct Snapshot: Equatable, Sendable {
        let enqueuedItems: Int
        let startedItems: Int
        let successfulItems: Int
        let attemptedOperations: Int
        let successfulOperations: Int
        let failures: Int
        let cancelledItems: Int
        let supersededItems: Int
        let averageQueueDelayMs: Double?
        let averageNetworkDurationMs: Double?
        let cadenceSeconds: Double?

        static let empty = Snapshot(
            enqueuedItems: 0, startedItems: 0, successfulItems: 0,
            attemptedOperations: 0, successfulOperations: 0, failures: 0,
            cancelledItems: 0, supersededItems: 0,
            averageQueueDelayMs: nil, averageNetworkDurationMs: nil,
            cadenceSeconds: nil)
    }

    /// Newest completion older than this (relative to the snapshot's `asOf`)
    /// means the number on screen would be stale — report no cadence instead.
    private static let cadenceHorizonSeconds: Double = 5.0
    /// Bounded memory: cadence needs only a short recent history, never an
    /// unbounded completion log.
    private static let maxCompletionTimestamps = 32

    private struct SessionKey: Hashable {
        let bridgeKey: String
        let scope: RestScope
    }

    /// Where a retained token sits in its lifecycle. Terminal tokens are not
    /// retained at all — removal IS the terminal marker, which is what makes
    /// duplicate terminals free to ignore.
    private enum TokenState {
        case enqueued(at: CFAbsoluteTime)
        case started(enqueuedAt: CFAbsoluteTime, startedAt: CFAbsoluteTime)
    }

    private struct Session {
        let generation: Int
        var tokens: [Token: TokenState] = [:]

        var enqueuedItems = 0
        var startedItems = 0
        var successfulItems = 0
        var attemptedOperations = 0
        var successfulOperations = 0
        var failures = 0
        var cancelledItems = 0
        var supersededItems = 0

        // Duration totals as SCALARS (bounded memory) — a sample enters each
        // total exactly once, on the transition that proves it.
        var queueDelayTotalMs = 0.0
        var queueDelaySamples = 0
        var networkDurationTotalMs = 0.0
        var networkDurationSamples = 0

        /// Completion times of CONTRIBUTING items (terminal with at least one
        /// successful operation). Rolling: newest 32, pruned past the horizon.
        var completionTimestamps: [CFAbsoluteTime] = []

        /// Shared tail of both terminal events. `successfulOperations` is
        /// DERIVED (max(0, attempted − failures)) so a partial batch preserves
        /// both sides, and a CONTRIBUTING item — one with at least one
        /// successful operation — counts toward `successfulItems` and leaves a
        /// cadence timestamp whether it completed or was cancelled mid-flight.
        /// All-failed and zero-operation items leave neither.
        mutating func recordTerminalOutcome(
            at time: CFAbsoluteTime, attemptedOperations: Int, failures: Int
        ) {
            self.attemptedOperations += attemptedOperations
            self.failures += failures
            let successful = max(0, attemptedOperations - failures)
            successfulOperations += successful
            guard successful >= 1 else { return }
            successfulItems += 1
            completionTimestamps.append(time)
            // Prune against the newest RETAINED timestamp, not a wall clock
            // this pure type does not have; the snapshot re-filters against
            // its own `asOf` anyway. Then cap to the newest 32.
            if let newest = completionTimestamps.max() {
                let windowStart = newest - CompositionSendLedger.cadenceHorizonSeconds
                completionTimestamps.removeAll { $0 < windowStart }
            }
            if completionTimestamps.count > CompositionSendLedger.maxCompletionTimestamps {
                completionTimestamps.sort()
                completionTimestamps.removeFirst(
                    completionTimestamps.count - CompositionSendLedger.maxCompletionTimestamps)
            }
        }
    }

    private var sessions: [SessionKey: Session] = [:]

    // MARK: Session lifecycle

    /// Open a fresh session, discarding EVERYTHING the prior one retained —
    /// even when `generation` repeats the previous value. Generation rejection
    /// alone cannot fence a new transport window from an old executing
    /// completion; the blank slate can, because the old token no longer exists.
    /// Publication is deliberately NOT touched here — the orchestrator's
    /// session helper owns that.
    mutating func beginSession(bridgeKey: String, scope: RestScope, generation: Int) {
        sessions[SessionKey(bridgeKey: bridgeKey, scope: scope)] =
            Session(generation: generation)
    }

    /// Close a session: lifecycle mirror of `beginSession`, NOT a telemetry
    /// event. Acts only when `generation` is the session's ACTIVE generation —
    /// a stale deactivation (from work that outlived a restart) must not kill
    /// the successor session. After deactivation nothing remains: no active
    /// generation, no retained tokens, no counters, no timestamps — so every
    /// later report from the deactivated generation falls through both gates
    /// and is ignored, and `snapshot` returns `.empty`.
    mutating func deactivateSession(bridgeKey: String, scope: RestScope, generation: Int) {
        let key = SessionKey(bridgeKey: bridgeKey, scope: scope)
        guard sessions[key]?.generation == generation else { return }
        sessions.removeValue(forKey: key)
    }

    // MARK: Events

    /// Work entered the mailbox. Recorded only for the active generation, and
    /// only for a token not already retained (a duplicate enqueue report is a
    /// caller bug, not a second item).
    mutating func enqueued(_ token: Token, at time: CFAbsoluteTime) {
        withActiveSession(for: token) { session in
            guard session.tokens[token] == nil else { return false }
            session.tokens[token] = .enqueued(at: time)
            session.enqueuedItems += 1
            return true
        }
    }

    /// The mailbox dispatched the work. Valid only from `enqueued`; this is
    /// the ONE place a queue-delay sample is taken.
    mutating func started(_ token: Token, at time: CFAbsoluteTime) {
        withActiveSession(for: token) { session in
            guard case .enqueued(let enqueuedAt) = session.tokens[token] else { return false }
            session.tokens[token] = .started(enqueuedAt: enqueuedAt, startedAt: time)
            session.startedItems += 1
            session.queueDelayTotalMs += (time - enqueuedAt) * 1000
            session.queueDelaySamples += 1
            return true
        }
    }

    /// The work ran to its natural end. Valid only from `started` —
    /// completed-before-started is a report about work this session never saw
    /// dispatch, and is dropped.
    ///
    /// Returns whether the strict transition was ACCEPTED — true only when the
    /// exact session and generation are active, the token was retained in the
    /// `started` state, and this call processed the terminal and removed it.
    /// False for absent tokens, stale generations, completed-before-started,
    /// duplicates, and every other invalid transition. The orchestrator gates
    /// runtime send bookkeeping on this: an ignored report must never look like
    /// a send that happened.
    @discardableResult
    mutating func completed(
        _ token: Token,
        at time: CFAbsoluteTime,
        attemptedOperations: Int,
        failures: Int
    ) -> Bool {
        withActiveSession(for: token) { session in
            guard case .started(_, let startedAt) = session.tokens[token] else { return false }
            session.tokens.removeValue(forKey: token)
            session.networkDurationTotalMs += (time - startedAt) * 1000
            session.networkDurationSamples += 1
            session.recordTerminalOutcome(
                at: time, attemptedOperations: attemptedOperations, failures: failures)
            return true
        }
    }

    /// The work was invalidated. TWO legal shapes:
    ///   • from `enqueued` — a PENDING cancellation, reported only on
    ///     `RestSender`'s word (`clear` returned true / `clearAll` returned the
    ///     scope). It never ran, so no operation could have succeeded or failed
    ///     and no duration sample of either kind is taken. The outcome is
    ///     NORMALIZED to 0/0 here rather than trusted from the caller —
    ///     never-started work reporting operations is impossible by definition,
    ///     and impossible counts must not enter the snapshot;
    ///   • from `started` — cooperative cancellation of EXECUTING work at a
    ///     failed probe, carrying whatever operations ran first. Successes
    ///     dispatched before the probe still count (successfulItems and
    ///     cancelledItems are intentionally not mutually exclusive).
    ///
    /// Returns whether the transition was ACCEPTED, on the same terms as
    /// `completed`: false for absent tokens, stale generations, duplicates,
    /// and every other invalid shape.
    @discardableResult
    mutating func cancelled(
        _ token: Token,
        at time: CFAbsoluteTime,
        attemptedOperations: Int,
        failures: Int
    ) -> Bool {
        withActiveSession(for: token) { session in
            switch session.tokens[token] {
            case .enqueued:
                session.tokens.removeValue(forKey: token)
                session.cancelledItems += 1
                session.recordTerminalOutcome(
                    at: time, attemptedOperations: 0, failures: 0)
            case .started(_, let startedAt):
                session.tokens.removeValue(forKey: token)
                session.networkDurationTotalMs += (time - startedAt) * 1000
                session.networkDurationSamples += 1
                session.cancelledItems += 1
                session.recordTerminalOutcome(
                    at: time, attemptedOperations: attemptedOperations, failures: failures)
            case nil:
                return false
            }
            return true
        }
    }

    /// A later enqueue overwrote this token's pending slot — reported only when
    /// `enqueue` returned `replacedPending == true`. Valid only from
    /// `enqueued`: a started item has left the slot, so a supersession report
    /// against it is the inference error this ledger exists to reject. No
    /// timestamp: nothing happened to the work; it simply never will.
    mutating func superseded(_ token: Token) {
        withActiveSession(for: token) { session in
            guard case .enqueued = session.tokens[token] else { return false }
            session.tokens.removeValue(forKey: token)
            session.supersededItems += 1
            return true
        }
    }

    // MARK: Snapshot

    /// Aggregate view of one session as of a caller-supplied instant. Inactive
    /// session → `.empty`. Cadence is the mean interval between CONTRIBUTING
    /// completions inside the rolling horizon: (latest − oldest) / (n − 1) —
    /// n items span n−1 intervals, the off-by-one the old telemetry got wrong.
    /// nil below two contributing items in the window, which also covers "the
    /// newest completion is older than the horizon".
    func snapshot(bridgeKey: String, scope: RestScope, asOf: CFAbsoluteTime) -> Snapshot {
        guard let session = sessions[SessionKey(bridgeKey: bridgeKey, scope: scope)] else {
            return .empty
        }

        let windowStart = asOf - Self.cadenceHorizonSeconds
        let contributing = session.completionTimestamps.filter { $0 >= windowStart }
        var cadenceSeconds: Double? = nil
        if contributing.count >= 2,
           let oldest = contributing.min(),
           let latest = contributing.max() {
            cadenceSeconds = (latest - oldest) / Double(contributing.count - 1)
        }

        return Snapshot(
            enqueuedItems: session.enqueuedItems,
            startedItems: session.startedItems,
            successfulItems: session.successfulItems,
            attemptedOperations: session.attemptedOperations,
            successfulOperations: session.successfulOperations,
            failures: session.failures,
            cancelledItems: session.cancelledItems,
            supersededItems: session.supersededItems,
            averageQueueDelayMs: session.queueDelaySamples > 0
                ? session.queueDelayTotalMs / Double(session.queueDelaySamples) : nil,
            averageNetworkDurationMs: session.networkDurationSamples > 0
                ? session.networkDurationTotalMs / Double(session.networkDurationSamples) : nil,
            cadenceSeconds: cadenceSeconds)
    }

    // MARK: Private

    /// Both admission gates in one place: the session must exist for the
    /// token's (bridgeKey, scope) AND its active generation must be the
    /// token's. Everything else — state fitness — is the caller's `guard`
    /// against `session.tokens[token]`. A rejected gate yields `false` for the
    /// Bool-returning terminal events and is a plain no-op for the rest.
    @discardableResult
    private mutating func withActiveSession(
        for token: Token, _ body: (inout Session) -> Bool
    ) -> Bool {
        let key = SessionKey(bridgeKey: token.bridgeKey, scope: token.scope)
        guard var session = sessions[key], session.generation == token.generation else {
            return false
        }
        let accepted = body(&session)
        sessions[key] = session
        return accepted
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Rolling-subset rotation (Composer 2 packet 5)
// ──────────────────────────────────────────────────────────────

/// The pure arithmetic behind fair rolling delivery for rooms with more
/// eligible REST operations than one sweep may dispatch.
///
/// Pure and parameterised so ordering, partitioning and no-starvation are
/// provable without an orchestrator, a clock, or a network. `limit` is a
/// parameter ONLY so small examples stay readable in tests — production
/// always uses `maxOperationsPerSweep`, and there is deliberately no runtime
/// override anywhere.
enum CompositionRotationPlan {

    /// Concurrent operations dispatched per batch. Matches the Composer REST
    /// closures' existing `batchSize`.
    static let batchSize = 5

    /// Batches one sweep runs before the frame is replaced. Matches what the
    /// closures already do for a full 20-light room (four batches, 80 ms
    /// apart).
    static let maxBatchesPerSweep = 4

    /// The most REST operations one Composer sweep may dispatch.
    ///
    /// DERIVED, not chosen: holding `batchSize × maxBatchesPerSweep` constant
    /// keeps per-sweep bridge load byte-identical to pre-packet-5 behaviour
    /// for every room that works today, so rooms of 1…20 operations are
    /// completely unaffected and only larger rooms begin to rotate.
    ///
    /// This is a COMPATIBILITY bound, not a bridge-capability bound. The
    /// repo's own stated sustainable budget is ~10 commands/sec
    /// (`RestSender`, `BridgeCommandGate`), which 20-per-sweep already
    /// exceeds; right-sizing it against a real token bucket belongs to the
    /// later scheduler work, not here.
    static let maxOperationsPerSweep = batchSize * maxBatchesPerSweep   // 20

    /// One sweep's contiguous, NON-WRAPPING window into the eligible list.
    struct Slice: Equatable {
        let start: Int
        let count: Int
        var range: Range<Int> { start ..< (start + count) }
    }

    /// The window this sweep should dispatch, or nil when there is nothing
    /// eligible.
    ///
    /// Never wraps. A sweep stops at the rotation boundary and the next sweep
    /// resumes from 0, so each rotation is an exact ordered partition of
    /// `[0, n)`: 21 operations go 20 then 1, 64 go 20, 20, 20, 4. Wrapping
    /// would repeat the head of the list before the tail had ever been
    /// served, which is what makes "every operation exactly once per
    /// rotation" — and therefore quiescence on a static look — provable.
    static func slice(
        cursor: Int,
        eligibleCount n: Int,
        limit: Int = maxOperationsPerSweep
    ) -> Slice? {
        guard n > 0, limit > 0 else { return nil }
        let start = cursor >= 0 && cursor < n ? cursor : 0
        return Slice(start: start, count: min(limit, n - start))
    }

    /// Where the cursor lands after `attemptedOperations` were dispatched, and
    /// whether that crossed a rotation boundary.
    ///
    /// Under the non-wrapping invariant `cursor + attempted` can only reach
    /// `n`, never exceed it; `>=` is a defensive fold, never a wrap.
    struct Advance: Equatable {
        let cursor: Int
        let crossedRotationBoundary: Bool
    }

    static func advance(
        cursor: Int,
        eligibleCount n: Int,
        attemptedOperations: Int
    ) -> Advance {
        guard n > 0 else { return Advance(cursor: 0, crossedRotationBoundary: false) }
        let next = cursor + max(0, attemptedOperations)
        return next >= n
            ? Advance(cursor: 0, crossedRotationBoundary: true)
            : Advance(cursor: next, crossedRotationBoundary: false)
    }

    /// Whether rolling delivery must hold the delta gate OPEN — i.e. the room
    /// has not yet earned the right to quiesce.
    ///
    /// True mid-rotation (`cursor != 0`: the remaining lights still need their
    /// turn) and until one rotation has fully DELIVERED (`hasCompleted…`
    /// false: attempted-but-failed is not delivered).
    ///
    /// An EMPTY eligible set is trivially complete, never incomplete. That is
    /// the grouped fallback — no per-light IDs resolved, so rotation state is
    /// armed with a count of 0, the grouped closure never reports a rotation
    /// advance, and the flag could never rise. Without this short-circuit the
    /// gate would be held open forever and a static grouped room would re-send
    /// an identical PUT every tick instead of going quiet.
    static func deliveryIncomplete(
        eligibleOperationCount: Int,
        hasCompletedInitialSuccessfulRotation: Bool,
        cursor: Int
    ) -> Bool {
        eligibleOperationCount > 0
            && (!hasCompletedInitialSuccessfulRotation || cursor != 0)
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - Transport degradation (Composer 2 packet 5)
// ──────────────────────────────────────────────────────────────
//
// These two types live here, beside CompositionSendLedger, for the same
// reason it does: the HueHome target is not file-system-synchronized, so a
// new .swift file means a hand-edited project.pbxproj and avoidable
// build-breakage risk. They are module-internal on purpose — the mixer tray
// reads them, and the tray must not depend on a private UnifiedOrchestrator
// implementation type.

/// Why a composition is NOT on the transport it asked for.
///
/// Deliberately separate from the large-room fact below: a bridge that
/// couldn't store a look for a 60-light room is BOTH "we couldn't store this"
/// and "lights take turns", and neither statement may erase the other.
enum CompositionFallbackReason: Equatable, Sendable {
    /// Streaming was requested or preferred but is not available.
    case entertainmentUnavailable
    /// The bridge REPORTED less free capacity than this look measurably needs.
    /// This is the only reason permitted to say the bridge is full.
    case bridgeCapacityInsufficient
    /// Capacity could not be fetched or decoded, so bridge-stored failed
    /// closed. The app does NOT know the bridge is full — it knows nothing.
    case bridgeCapacityUnknown
    /// A resource creation failed after a passing preflight (or for any other
    /// non-capacity reason). Deliberately generic: preflight is a
    /// point-in-time check, not a reservation, and a later failure is not
    /// evidence of exhaustion.
    case bridgeStoredUploadFailed
}

/// Immutable read model handed to the UI.
///
/// Carries no generation and no keys — the caller already named the exact
/// room and bridge to obtain it. The mutable state behind it stays private
/// to `UnifiedOrchestrator`.
struct CompositionDegradationSnapshot: Equatable, Sendable {
    /// nil when the composition is on its intended transport.
    let fallbackReason: CompositionFallbackReason?
    /// Non-nil when the room has more eligible REST operations than one sweep
    /// may dispatch, i.e. its lights are being served in rotation.
    let largeRoomEligibleOperations: Int?

    var isLargeRoom: Bool { largeRoomEligibleOperations != nil }

    /// Nothing worth telling the user about.
    var isEmpty: Bool { fallbackReason == nil && largeRoomEligibleOperations == nil }
}

#if DEBUG
extension CompositionSendLedger {
    /// Test-only introspection for the bounded-memory contract. Matches the
    /// orchestrator's DEBUG-seam convention: readers only, no production path.
    func debugRetainedTokenCount(bridgeKey: String, scope: RestScope) -> Int {
        sessions[SessionKey(bridgeKey: bridgeKey, scope: scope)]?.tokens.count ?? 0
    }

    func debugCompletionTimestampCount(bridgeKey: String, scope: RestScope) -> Int {
        sessions[SessionKey(bridgeKey: bridgeKey, scope: scope)]?.completionTimestamps.count ?? 0
    }
}
#endif
