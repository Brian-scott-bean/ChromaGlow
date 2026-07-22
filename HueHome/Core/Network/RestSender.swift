// RestSender.swift
// ChromaGlow — REST latest-wins mailbox
//
// Extracted verbatim from UI/Sync/SyncModeEngine.swift (2026-07-22) when the
// dead Sync-engine stack was deleted — this actor was the one live thing in
// that file (UnifiedOrchestrator's allDayRestSender + studioRestSender).
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

import Foundation

actor RestSender {
    private var isInflight = false
    // @Sendable @MainActor function type: the enqueued closures are formed
    // inside @MainActor methods and already execute on the main actor today
    // (they synchronously touch main-actor state). @MainActor isolation lets
    // a @Sendable closure legally capture that non-Sendable main-actor state
    // (SE-0434), and @Sendable lets the value cross into this actor.
    // Nonisolated closures (enqueueStudioRestWrite) convert implicitly.
    private var pending: (@Sendable @MainActor () async -> Void)?

    /// Enqueue work. If something is already in-flight the closure overwrites
    /// any previous pending value (old one is silently dropped).
    func enqueue(_ work: @escaping @Sendable @MainActor () async -> Void) {
        pending = work          // always latest — overwrites stale pending
        guard !isInflight else { return }
        Task { await flush() }
    }

    private func flush() async {
        while let work = pending {
            pending    = nil
            isInflight = true
            await work()
        }
        isInflight = false
    }

    /// Drop any queued pending work (does not interrupt in-flight request).
    func clear() {
        pending = nil
    }
}
