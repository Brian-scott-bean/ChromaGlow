// BridgeCommandGate.swift
// ChromaGlow — audit M-08/M-14/M-15.
//
// Per-bridge pacing gate for one-shot bulk writes and effect-loop frames.
// The bridge processes ~10 commands/sec and silently drops the excess, so
// unpaced N-room bursts (All Off, automations) and high-frequency effect
// loops lost commands with `try?` hiding every failure.
//
// This is NOT the latest-wins RestSender (which is for streams where only the
// newest state matters): bulk operations must deliver EVERY command, so the
// gate spaces command starts to the bridge budget and retries once with
// backoff before reporting the failure to the caller.

import Foundation

actor BridgeCommandGate {

    /// ~10 commands/sec — the practical bridge REST budget.
    static let minInterval: Duration = .milliseconds(100)
    /// One retry after this backoff — transient 429/503 bursts clear quickly.
    static let retryBackoff: Duration = .milliseconds(400)

    private var lastSend: ContinuousClock.Instant?

    /// Runs `op` after enforcing the per-bridge spacing. On error, retries
    /// once after a backoff (unless `retry` is false — effect loops pass
    /// false because the NEXT frame supersedes a failed one; retrying a
    /// stale frame is wasted budget). Returns nil on success, the final
    /// error on failure — callers surface it instead of `try?`-dropping it.
    /// A cancelled task returns CancellationError without sending: the
    /// caller's loop is being torn down and one more command would flash
    /// the lights after the user pressed stop.
    @discardableResult
    func send(retry: Bool = true,
              _ op: @escaping @Sendable () async throws -> Void) async -> Error? {
        await pace()
        guard !Task.isCancelled else { return CancellationError() }
        do {
            try await op()
            return nil
        } catch {
            guard retry, !Task.isCancelled else { return error }
            try? await Task.sleep(for: Self.retryBackoff)
            guard !Task.isCancelled else { return error }
            await pace()
            do {
                try await op()
                return nil
            } catch {
                return error
            }
        }
    }

    /// Sleeps until at least `minInterval` has passed since the previous
    /// command START on this bridge. Actor reentrancy makes concurrent
    /// callers queue up in ~minInterval steps. Exits early on cancellation
    /// (Task.sleep throws immediately on a cancelled task — looping on it
    /// would busy-spin the actor).
    private func pace() async {
        while let last = lastSend, !Task.isCancelled {
            let elapsed = last.duration(to: .now)
            if elapsed >= Self.minInterval { break }
            try? await Task.sleep(for: Self.minInterval - elapsed)
        }
        lastSend = .now
    }
}
