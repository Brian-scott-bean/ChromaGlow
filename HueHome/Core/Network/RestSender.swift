// RestSender.swift
// ChromaGlow — SCOPED REST latest-wins mailbox
//
// Extracted verbatim from UI/Sync/SyncModeEngine.swift (2026-07-22) when the
// dead Sync-engine stack was deleted — this actor was the one live thing in
// that file (UnifiedOrchestrator's All-Day and Studio mailboxes).
//
// Solves the "bridge backlog" problem inherent to REST vs Entertainment API:
//
//   Entertainment (UDP/DTLS): connectionless. Bridge applies the LATEST packet
//   immediately, dropping older unprocessed ones. Zero queue. Zero latency.
//
//   REST (HTTP/TCP): sequential. Bridge processes each PUT in order. If we
//   send faster than ~10 req/s the queue grows, lights replay stale values.
//
// Solution — mailbox pattern:
//   • Only 1 HTTP request in-flight at a time.
//   • New values overwrite the pending slot — stale intermediate values dropped.
//   • After in-flight completes, immediately sends latest pending (if any).
//   • Max bridge queue depth: 1 (in-flight) + 1 (pending). Never deeper.
//
// Result: bridge always sees the LATEST desired state, not a backlog.
//
// ─────────────────────────────────────────────────────────────────────────
// Composer 2 / Phase 0 / Packet 3 — SCOPING AND COOPERATIVE CANCELLATION
//
// The original actor held ONE pending slot and ONE global clear(). A single
// instance served every Composer room, every Studio engine loop, and every
// Studio live-param write, across every bridge — so:
//
//   1. clear() was global. Stopping room A discarded room B's queued frame.
//      Worse, the composition scheduler had already recorded lastSentX/Y/Bri
//      for the frame that got thrown away, so its delta gate then SKIPPED the
//      re-render — a stopped room could freeze a running room's colour.
//   2. clear() could not stop work that was already executing. The Composer
//      closures loop over 5-light batches with 80 ms sleeps between them;
//      nothing in the loop ever asked whether it was still wanted, so 300-500
//      ms of stale writes could land AFTER the replacement prime frame.
//   3. Task.isCancelled was useless as a fix. The flush task is unstructured,
//      unowned, and never cancelled, so Task.isCancelled is permanently false
//      inside an enqueued closure. (That also makes BridgeCommandGate's own
//      cancellation guards inert when it is driven from inside one.)
//   4. The one-in-flight guarantee had a scheduling race: the in-flight flag
//      was only set once the separately spawned flush task began running, so
//      two enqueues arriving before the first flush was scheduled spawned two
//      flush tasks — permitting exactly the concurrency the mailbox exists to
//      prevent.
//
// The fix, in order:
//   • Latest-wins is now per SCOPE — (roomID, owner) — not per instance, and
//     bridge isolation comes from the OWNING DICTIONARY (UnifiedOrchestrator's
//     restSendersByBridge), never from a field inside the scope.
//   • Every scope carries a monotonic epoch. Each enqueued closure receives a
//     ValidityProbe bound to the epoch it was stored under; clear(scope:)
//     bumps that epoch, so a running closure can ask "am I still wanted?" at
//     each batch boundary and return early. This is cooperative cancellation
//     that does not depend on Task.isCancelled.
//   • ONE lifecycle flag (isFlushing), set SYNCHRONOUSLY inside enqueue before
//     the flush task is spawned — closing the race in defect 4.

import Foundation

/// Who owns a mailbox slot. Composer and Studio may target the SAME room at
/// the same time (a Studio slider while a composition runs elsewhere on the
/// bridge), so the owner is part of the key — otherwise one would silently
/// overwrite and cancel the other.
enum RestScopeOwner: String, Hashable, Sendable {
    case composer
    case studio
    case allDay
}

/// The unit of latest-wins and of cancellation.
///
/// Deliberately carries NO bridgeID. Bridge identity belongs to the dictionary
/// that owns the sender (`UnifiedOrchestrator.restSendersByBridge`); putting it
/// here too would let the dictionary key and the scope value disagree, and a
/// clear() aimed at the wrong sender silently does nothing.
struct RestScope: Hashable, Sendable {
    let roomID: String
    let owner: RestScopeOwner

    init(roomID: String, owner: RestScopeOwner) {
        self.roomID = roomID
        self.owner = owner
    }
}

typealias RestEpoch = UInt64

actor RestSender {

    /// Asks the sender whether the closure that holds it is still the current
    /// occupant of its scope. Returns false once `clear(scope:)`/`clearAll()`
    /// has invalidated the epoch the closure was stored under.
    typealias ValidityProbe = @Sendable () async -> Bool

    /// Enqueued work.
    ///
    /// @MainActor function type: these closures are formed inside @MainActor
    /// methods and already execute on the main actor today (they synchronously
    /// touch main-actor state). @MainActor isolation lets a @Sendable closure
    /// legally capture that non-Sendable main-actor state (SE-0434), and
    /// @Sendable lets the value cross into this actor.
    ///
    /// Single-request work may ignore the probe (`{ _ in ... }`). Anything that
    /// loops — batches, paced per-light sweeps — MUST check it before each
    /// dispatch, including the first.
    /// (`@escaping` so a closure may hold the probe past its own call — the
    /// batch loops call it inline, but tests capture it to observe what a
    /// RUNNING closure would see.)
    typealias Work = @Sendable @MainActor (@escaping ValidityProbe) async -> Void

    /// At most one outstanding work item per scope: newer work for a scope
    /// replaces the older one (latest-wins WITHIN A SCOPE ONLY).
    private var pending: [RestScope: (epoch: RestEpoch, work: Work)] = [:]

    /// FIFO fairness across scopes — without it, dictionary order decides which
    /// room's frame the bridge sees next, and a busy scope can starve a quiet
    /// one indefinitely.
    private var order: [RestScope] = []

    /// Monotonic validity counter per scope. Bumped ONLY by clear/clearAll.
    private var epochs: [RestScope: RestEpoch] = [:]

    /// The SINGLE lifecycle flag. There is deliberately no second authoritative
    /// flag (no isInflight + flushTask pair) — two of them is what allowed a
    /// second flush task to clear the flag out from under the first.
    private var isFlushing = false

    // ──────────────────────────────────────────────
    // MARK: - API
    // ──────────────────────────────────────────────

    /// Enqueue work for a scope. If that scope already has pending work, this
    /// REPLACES it (the old closure is silently dropped and never runs).
    ///
    /// Does NOT bump the epoch — enqueueing is not invalidation. Work stored
    /// here inherits the scope's current epoch, so a later `clear(scope:)` can
    /// invalidate it whether it has started or not.
    func enqueue(scope: RestScope, _ work: @escaping Work) {
        let epoch = epochs[scope] ?? 0
        // Record the scope even at epoch 0. `clearAll` invalidates what it
        // KNOWS about, and a scope whose work is currently executing is in
        // neither `pending` (flush removed it) nor, without this, `epochs` —
        // so a stop-everything would have missed exactly the closure that was
        // still writing to the bridge.
        epochs[scope] = epoch
        if pending[scope] == nil { order.append(scope) }
        pending[scope] = (epoch: epoch, work: work)

        guard !isFlushing else { return }
        // Set SYNCHRONOUSLY, inside this actor turn, BEFORE spawning — a second
        // enqueue arriving before the flush task is scheduled must observe it.
        isFlushing = true
        Task { await self.flush() }
    }

    /// Invalidate one scope.
    ///
    /// GUARANTEED once this returns:
    ///   • pending work for that scope is removed (it will never start);
    ///   • the epoch is invalidated, so an executing closure's probe returns
    ///     false and it stops before entering its NEXT batch / next light;
    ///   • at most the already-dispatched batch or request remains;
    ///   • every other scope — other rooms, the other owner on the same room,
    ///     and (by construction) every other bridge's sender — is untouched.
    ///
    /// NOT GUARANTEED:
    ///   • that an HTTP request already in flight completes before the
    ///     replacement prime frame;
    ///   • that the prime is the final write to those lights.
    ///
    /// Stated precisely: the old scope is invalidated before the replacement
    /// prime; an already-dispatched batch may still complete, but no later
    /// batch may begin.
    func clear(scope: RestScope) {
        epochs[scope, default: 0] &+= 1     // stops work that is EXECUTING
        pending.removeValue(forKey: scope)  // stops work that has not STARTED
        order.removeAll { $0 == scope }
    }

    /// Invalidate everything this sender knows about (forget-all / stop-all).
    ///
    /// Ordering matters: every epoch is bumped FIRST, so a closure executing
    /// right now observes invalidation. Clearing pending first would leave a
    /// window where a running closure's probe still returned true.
    func clearAll() {
        // `enqueue` seeds `epochs` for every scope it has ever seen, so this
        // covers work that is PENDING and work that is EXECUTING right now.
        // Snapshot the keys: the loop mutates `epochs`.
        let known = Array(epochs.keys)
        for scope in known {
            epochs[scope, default: 0] &+= 1
        }
        pending.removeAll()
        order.removeAll()
    }

    /// Is `epoch` still the live epoch for `scope`? Backs every ValidityProbe.
    func isCurrent(scope: RestScope, epoch: RestEpoch) -> Bool {
        (epochs[scope] ?? 0) == epoch
    }

    // ──────────────────────────────────────────────
    // MARK: - Flush
    // ──────────────────────────────────────────────

    private func flush() async {
        while true {
            guard let scope = order.first else {
                // Proven empty in THIS actor turn — the only place the flag is
                // allowed to go back down.
                isFlushing = false
                return
            }
            order.removeFirst()
            guard let entry = pending.removeValue(forKey: scope) else { continue }

            let epoch = entry.epoch
            // Already invalidated between enqueue and now — never start it.
            guard (epochs[scope] ?? 0) == epoch else { continue }

            let probe: ValidityProbe = { [weak self] in
                guard let self else { return false }
                return await self.isCurrent(scope: scope, epoch: epoch)
            }

            // The actor suspends here, so a re-entrant enqueue/clear from
            // inside the closure runs normally: isFlushing is already true so
            // no second flush spawns, and this loop picks the new work up.
            await entry.work(probe)
        }
    }
}
