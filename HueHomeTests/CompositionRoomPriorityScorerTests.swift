import XCTest
@testable import HueHome

final class CompositionRoomPriorityScorerTests: XCTestCase {
    func testDueGateReturnsNilWhenNotYetDue() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(nextDueAt: now + 0.005, startTime: now)
        XCTAssertNil(CompositionRoomPriorityScorer.score(now: now, input: input))
    }

    func testDueGateBoundaryIsEligible() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(nextDueAt: now + 0.004, startTime: now)
        XCTAssertEqual(eligibleScore(now: now, input: input), 0, accuracy: 0.000001)
    }

    func testOverdueIsEligible() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(nextDueAt: now - 0.5, startTime: now)
        XCTAssertNotNil(CompositionRoomPriorityScorer.score(now: now, input: input))
    }

    func testBaseEligibleScoreWithoutBoostsIsZero() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(nextDueAt: now, startTime: now)
        XCTAssertEqual(eligibleScore(now: now, input: input), 0, accuracy: 0.000001)
    }

    func testInteractionAddsOneThousand() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, isColorPadInteracting: true)
        )
        XCTAssertEqual(score, 1000, accuracy: 0.000001)
    }

    func testInteractionBurstAddsFiveHundred() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, interactionBurstUntil: now + 2)
        )
        XCTAssertEqual(score, 500, accuracy: 0.000001)
    }

    func testPendingSettleAddsTwoSixty() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, pendingSettle: true)
        )
        XCTAssertEqual(score, 260, accuracy: 0.000001)
    }

    func testOverdueContributionUsesLinearTerm() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now - 1, startTime: now)
        )
        XCTAssertEqual(score, 120, accuracy: 0.000001)
    }

    func testOverdueContributionCapsAtTwoTwenty() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now - 10, startTime: now)
        )
        XCTAssertEqual(score, 220, accuracy: 0.000001)
    }

    func testStaleSendNoBoostThroughThreshold() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now - 1.4)
        )
        XCTAssertEqual(score, 0, accuracy: 0.000001)
    }

    func testStaleSendContributionUsesLinearTerm() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now - 2.4)
        )
        XCTAssertEqual(score, 45, accuracy: 0.000001)
    }

    func testStaleSendContributionCapsAtOneSixty() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now - 10)
        )
        XCTAssertEqual(score, 160, accuracy: 0.000001)
    }

    func testStaleSendFallbackUsesStartTimeWhenLastSendMissing() {
        let now: CFAbsoluteTime = 100
        let withoutLastSend = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now - 2, lastSentAt: nil)
        )
        let withSameLastSend = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now - 50, lastSentAt: now - 2)
        )
        XCTAssertEqual(withoutLastSend, withSameLastSend, accuracy: 0.000001)
    }

    func testFairnessNudgeUsesModuloTerm() {
        let now: CFAbsoluteTime = 100
        let score = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, sendCount: 10)
        )
        XCTAssertEqual(score, -3.5, accuracy: 0.000001)
    }

    func testFairnessModuloRolloverIsPreserved() {
        let now: CFAbsoluteTime = 100
        let score120 = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, sendCount: 120)
        )
        let score121 = eligibleScore(
            now: now,
            input: baseInput(nextDueAt: now, startTime: now, sendCount: 121)
        )
        XCTAssertEqual(score120, 0, accuracy: 0.000001)
        XCTAssertEqual(score121, -0.35, accuracy: 0.000001)
    }

    func testCombinedScoreMatchesAllTermsExactly() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(
            nextDueAt: now - 3,            // overdue = 3 -> +220 cap
            startTime: now - 9,            // since = 9 -> +160 cap
            isColorPadInteracting: true,   // +1000
            interactionBurstUntil: now + 1,// +500
            pendingSettle: true,           // +260
            sendCount: 119                 // -41.65
        )
        let score = eligibleScore(now: now, input: input)
        XCTAssertEqual(score, 2098.35, accuracy: 0.000001)
    }

    func testDeterminismRepeatedCallsMatch() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(
            nextDueAt: now - 1.5,
            startTime: now - 3,
            isColorPadInteracting: true,
            interactionBurstUntil: now + 2,
            pendingSettle: true,
            sendCount: 37
        )
        let first = CompositionRoomPriorityScorer.score(now: now, input: input)
        let second = CompositionRoomPriorityScorer.score(now: now, input: input)
        XCTAssertEqual(first ?? .nan, second ?? .nan, accuracy: 0.000001)
    }

    func testInputValuesRemainUnchangedAfterScoring() {
        let now: CFAbsoluteTime = 100
        let input = baseInput(
            nextDueAt: 99.5,
            startTime: 98.0,
            interactionBurstUntil: 101.0,
            sendCount: 42
        )
        _ = CompositionRoomPriorityScorer.score(now: now, input: input)
        XCTAssertEqual(input.nextDueAt, 99.5)
        XCTAssertEqual(input.startTime, 98.0)
        XCTAssertEqual(input.interactionBurstUntil, 101.0)
        XCTAssertEqual(input.sendCount, 42)
    }

    /// Orchestrator selection tie behavior remains strict `>` over `compositionOrder`.
    func testTieBreakingRemainsDocumentedAsStrictGreaterThanInOrchestrator() {
        let path = #filePath.replacingOccurrences(of: "HueHomeTests/CompositionRoomPriorityScorerTests.swift", with: "HueHome/Core/Network/UnifiedOrchestrator.swift")
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("Failed to read UnifiedOrchestrator source")
            return
        }

        XCTAssertTrue(source.contains("for roomID in compositionOrder"))
        XCTAssertTrue(source.contains("if score > selectedScore"))
    }

    private func baseInput(
        nextDueAt: CFAbsoluteTime,
        startTime: CFAbsoluteTime,
        isColorPadInteracting: Bool = false,
        interactionBurstUntil: CFAbsoluteTime? = nil,
        pendingSettle: Bool = false,
        lastSentAt: CFAbsoluteTime? = nil,
        sendCount: Int = 0
    ) -> CompositionRoomPriorityScorer.Input {
        .init(
            nextDueAt: nextDueAt,
            isColorPadInteracting: isColorPadInteracting,
            interactionBurstUntil: interactionBurstUntil,
            pendingSettle: pendingSettle,
            lastSentAt: lastSentAt,
            startTime: startTime,
            sendCount: sendCount
        )
    }

    private func eligibleScore(now: CFAbsoluteTime, input: CompositionRoomPriorityScorer.Input) -> Double {
        guard let score = CompositionRoomPriorityScorer.score(now: now, input: input) else {
            XCTFail("Expected eligible score but got nil")
            return .nan
        }
        return score
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 4: CompositionSendLedger (pure)
    // ──────────────────────────────────────────────
    //
    // Every timestamp below is an explicit CFAbsoluteTime literal, exactly like
    // the scorer tests above. NOTHING here waits — no sleeping, no waiters, no
    // timeouts. The hardening guard on this file pins that (and greps for the
    // banned tokens, which is why this comment names none of them).

    // MARK: Counters and derivation

    func testLedgerPartialBatchPreservesSuccessesAndFailures() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)

        ledger.enqueued(t, at: 10.0)
        ledger.started(t, at: 10.1)
        ledger.completed(t, at: 10.3, attemptedOperations: 5, failures: 2)

        let snapshot = snap(ledger)
        XCTAssertEqual(snapshot.attemptedOperations, 5)
        XCTAssertEqual(snapshot.failures, 2)
        XCTAssertEqual(snapshot.successfulOperations, 3, "derived: max(0, 5 - 2)")
        XCTAssertEqual(snapshot.successfulItems, 1)
        XCTAssertEqual(snapshot.cancelledItems, 0)
        XCTAssertEqual(snapshot.enqueuedItems, 1)
        XCTAssertEqual(snapshot.startedItems, 1)
    }

    func testLedgerAllFailedItemIsNotSuccessfulAndLeavesNoCadenceTimestamp() {
        var ledger = beganLedger()
        for sequence: UInt64 in 1...2 {
            let t = ledgerToken(sequence: sequence)
            let base = 10.0 + Double(sequence)
            ledger.enqueued(t, at: base)
            ledger.started(t, at: base + 0.1)
            ledger.completed(t, at: base + 0.2, attemptedOperations: 5, failures: 5)
        }

        let snapshot = snap(ledger, asOf: 13.0)
        XCTAssertEqual(snapshot.attemptedOperations, 10)
        XCTAssertEqual(snapshot.failures, 10)
        XCTAssertEqual(snapshot.successfulOperations, 0)
        XCTAssertEqual(snapshot.successfulItems, 0,
            "an all-failed batch is not a successful item")
        XCTAssertNil(snapshot.cadenceSeconds,
            "two all-failed terminals leave zero contributing completions")
        XCTAssertEqual(
            ledger.debugCompletionTimestampCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            0)
    }

    func testLedgerPartiallySuccessfulCancelledItemCountsBothAndContributesCadence() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)

        ledger.enqueued(t, at: 10.0)
        ledger.started(t, at: 10.1)
        // Probe failed after four of five operations succeeded (matrix item 9).
        ledger.cancelled(t, at: 10.4, attemptedOperations: 5, failures: 1)

        let snapshot = snap(ledger, asOf: 10.5)
        XCTAssertEqual(snapshot.successfulOperations, 4)
        XCTAssertEqual(snapshot.successfulItems, 1,
            "successfulItems and cancelledItems are intentionally not mutually exclusive")
        XCTAssertEqual(snapshot.cancelledItems, 1)
        XCTAssertEqual(
            ledger.debugCompletionTimestampCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            1, "a partially successful cancellation contributes one cadence timestamp")
        XCTAssertNotNil(snapshot.averageNetworkDurationMs,
            "it started, so its network duration is real and sampled")
    }

    func testLedgerDuplicateOrOutOfOrderTerminalReportsDoNotDoubleCount() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)

        ledger.enqueued(t, at: 10.0)
        ledger.started(t, at: 10.1)
        ledger.completed(t, at: 10.2, attemptedOperations: 3, failures: 0)
        let first = snap(ledger)

        // The token was removed by its first terminal — every later report is
        // about work that no longer exists.
        ledger.completed(t, at: 10.9, attemptedOperations: 3, failures: 0)
        ledger.cancelled(t, at: 11.0, attemptedOperations: 3, failures: 3)
        ledger.superseded(t)
        ledger.started(t, at: 11.1)

        XCTAssertEqual(snap(ledger), first,
            "terminal processing removes the token exactly once; duplicates change nothing")
        XCTAssertEqual(
            ledger.debugRetainedTokenCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            0)
    }

    func testLedgerSupersededAndCancelledAreDistinctCounters() {
        var ledger = beganLedger()
        let dropped = ledgerToken(sequence: 1)
        let replaced = ledgerToken(sequence: 2)

        ledger.enqueued(dropped, at: 10.0)
        ledger.cancelled(dropped, at: 10.1, attemptedOperations: 0, failures: 0)
        ledger.enqueued(replaced, at: 10.2)
        ledger.superseded(replaced)

        let snapshot = snap(ledger)
        XCTAssertEqual(snapshot.cancelledItems, 1)
        XCTAssertEqual(snapshot.supersededItems, 1)
        XCTAssertEqual(snapshot.successfulItems, 0)
    }

    // MARK: Durations

    func testLedgerMeasuresQueueDelayAndNetworkDurationHonestly() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)

        ledger.enqueued(t, at: 10.0)
        ledger.started(t, at: 10.05)          // 50 ms in the mailbox
        ledger.completed(t, at: 10.2, attemptedOperations: 1, failures: 0) // 150 ms on the wire

        let snapshot = snap(ledger)
        XCTAssertEqual(snapshot.averageQueueDelayMs ?? -1, 50, accuracy: 0.000001)
        XCTAssertEqual(snapshot.averageNetworkDurationMs ?? -1, 150, accuracy: 0.000001)
    }

    func testLedgerPendingCancellationAndSupersededLeaveNoDurationSamples() {
        var ledger = beganLedger()
        let pendingCancelled = ledgerToken(sequence: 1)
        let supersededToken = ledgerToken(sequence: 2)

        // Neither token ever starts: one is dropped by clear (RestSender
        // reported the removal; the orchestrator passes 0/0), one is
        // overwritten by a later enqueue.
        ledger.enqueued(pendingCancelled, at: 10.0)
        ledger.cancelled(pendingCancelled, at: 10.5, attemptedOperations: 0, failures: 0)
        ledger.enqueued(supersededToken, at: 10.6)
        ledger.superseded(supersededToken)

        let snapshot = snap(ledger)
        XCTAssertEqual(snapshot.cancelledItems, 1,
            "a pending cancellation from the enqueued state is accepted")
        XCTAssertEqual(snapshot.supersededItems, 1)
        XCTAssertNil(snapshot.averageQueueDelayMs,
            "work that never started has no queue-delay sample")
        XCTAssertNil(snapshot.averageNetworkDurationMs,
            "work that never started has no network-duration sample")
    }

    func testLedgerPendingCancellationNormalizesImpossibleOperationCounts() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)
        ledger.enqueued(t, at: 10.0)

        // Never-started work cannot have dispatched anything — a nonzero payload
        // here is a caller bug, and the ledger must not let it into the books.
        let accepted = ledger.cancelled(t, at: 10.5, attemptedOperations: 5, failures: 2)

        XCTAssertTrue(accepted, "the pending cancellation itself is a valid transition")
        let snapshot = snap(ledger, asOf: 10.5)
        XCTAssertEqual(snapshot.attemptedOperations, 0, "normalized: nothing was dispatched")
        XCTAssertEqual(snapshot.failures, 0)
        XCTAssertEqual(snapshot.successfulOperations, 0)
        XCTAssertEqual(snapshot.successfulItems, 0)
        XCTAssertEqual(snapshot.cancelledItems, 1)
        XCTAssertNil(snapshot.averageQueueDelayMs)
        XCTAssertNil(snapshot.averageNetworkDurationMs)
        XCTAssertEqual(
            ledger.debugCompletionTimestampCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            0, "impossible pending-operation counts must not mint a cadence timestamp")
    }

    func testLedgerTerminalEventsReportAcceptance() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)

        XCTAssertFalse(ledger.completed(t, at: 10.0, attemptedOperations: 1, failures: 0),
            "absent token: rejected")
        ledger.enqueued(t, at: 10.0)
        XCTAssertFalse(ledger.completed(t, at: 10.1, attemptedOperations: 1, failures: 0),
            "completed-before-started: rejected")
        ledger.started(t, at: 10.1)
        XCTAssertTrue(ledger.completed(t, at: 10.2, attemptedOperations: 1, failures: 0),
            "the honest transition is accepted")
        XCTAssertFalse(ledger.completed(t, at: 10.3, attemptedOperations: 1, failures: 0),
            "duplicate terminal: rejected")
        XCTAssertFalse(ledger.cancelled(t, at: 10.4, attemptedOperations: 0, failures: 0),
            "terminal after terminal: rejected")

        let stale = ledgerToken(generation: 99, sequence: 2)
        XCTAssertFalse(ledger.completed(stale, at: 10.5, attemptedOperations: 1, failures: 0),
            "stale generation: rejected")
    }

    // MARK: Cadence

    func testLedgerCadenceUsesIntervalsNotItemCount() {
        var ledger = beganLedger()
        // Three contributing completions at t = 0, 0.5, 1.0: three items span
        // TWO intervals, so cadence is 0.5 — not elapsed/items = 0.333.
        for (sequence, finishedAt) in [(UInt64(1), 0.0), (2, 0.5), (3, 1.0)] {
            completeContributingItem(in: &ledger, sequence: sequence, finishedAt: finishedAt)
        }

        let snapshot = snap(ledger, asOf: 1.0)
        XCTAssertEqual(snapshot.cadenceSeconds ?? -1, 0.5, accuracy: 0.000001)
    }

    func testLedgerCadenceIsNilBelowTwoContributingItems() {
        var ledger = beganLedger()
        completeContributingItem(in: &ledger, sequence: 1, finishedAt: 1.0)

        XCTAssertNil(snap(ledger, asOf: 1.0).cadenceSeconds,
            "one completion is a point, not an interval — the tray falls back to "
            + "roomModeCadenceStatus(nil)")
    }

    func testLedgerCadenceExpiresRelativeToAsOf() {
        var ledger = beganLedger()
        completeContributingItem(in: &ledger, sequence: 1, finishedAt: 0.0)
        completeContributingItem(in: &ledger, sequence: 2, finishedAt: 1.0)

        XCTAssertEqual(snap(ledger, asOf: 2.0).cadenceSeconds ?? -1, 1.0, accuracy: 0.000001,
            "inside the horizon the pair publishes")
        XCTAssertNil(snap(ledger, asOf: 7.0).cadenceSeconds,
            "the newest completion is 6 s old relative to asOf — past the 5 s horizon, "
            + "no number may stay on screen")
    }

    // MARK: Bounded memory

    func testLedgerMemoryStaysBoundedAfterFiveHundredTerminalItems() {
        var ledger = beganLedger()
        for sequence: UInt64 in 1...500 {
            // 1 ms apart keeps every completion inside the 5 s horizon, so the
            // newest-32 cap is what must do the bounding.
            completeContributingItem(
                in: &ledger, sequence: sequence,
                finishedAt: 100.0 + Double(sequence) * 0.001)
        }

        XCTAssertEqual(
            ledger.debugRetainedTokenCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            0, "terminal tokens are removed; the ledger retains only non-terminal work")
        XCTAssertLessThanOrEqual(
            ledger.debugCompletionTimestampCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            32)
        XCTAssertEqual(snap(ledger, asOf: 100.5).successfulItems, 500,
            "counters are scalars — bounding the timestamp list must not lose counts")
    }

    // MARK: Session lifecycle and strict transitions

    func testLedgerRejectsStaleGenerationReportsAfterRestart() {
        var ledger = beganLedger(generation: 1)
        let stale = ledgerToken(generation: 1, sequence: 1)
        ledger.enqueued(stale, at: 10.0)
        ledger.started(stale, at: 10.1)

        // Restart: the room begins generation 2.
        ledger.beginSession(
            bridgeKey: "bridge-1", scope: composerLedgerScope(), generation: 2)
        ledger.completed(stale, at: 10.5, attemptedOperations: 5, failures: 0)

        XCTAssertEqual(snap(ledger), .empty,
            "a generation-1 completion must not contaminate the generation-2 session")
    }

    func testLedgerBeginSessionWithSameGenerationStillClearsPriorState() {
        var ledger = beganLedger(generation: 3)
        let old = ledgerToken(generation: 3, sequence: 1)
        ledger.enqueued(old, at: 10.0)
        ledger.started(old, at: 10.1)

        // Same numeric generation — the reset must still fence the old work,
        // because generation equality alone cannot.
        ledger.beginSession(
            bridgeKey: "bridge-1", scope: composerLedgerScope(), generation: 3)

        ledger.started(old, at: 10.2)
        ledger.completed(old, at: 10.3, attemptedOperations: 5, failures: 0)

        XCTAssertEqual(snap(ledger), .empty, """
            the old token passes the generation gate by numeric accident, but its \
            state was wiped — both its started and completed reports are ignored
            """)
    }

    func testLedgerDeactivateSessionIgnoresLaterReportsAndSnapshotsEmpty() {
        var ledger = beganLedger(generation: 1)
        let finished = ledgerToken(generation: 1, sequence: 1)
        let executing = ledgerToken(generation: 1, sequence: 2)
        ledger.enqueued(finished, at: 10.0)
        ledger.started(finished, at: 10.1)
        ledger.completed(finished, at: 10.2, attemptedOperations: 2, failures: 0)
        ledger.enqueued(executing, at: 10.3)
        ledger.started(executing, at: 10.4)

        ledger.deactivateSession(
            bridgeKey: "bridge-1", scope: composerLedgerScope(), generation: 1)

        XCTAssertEqual(snap(ledger), .empty,
            "an inactive session snapshots as empty: zero counters, nil averages, nil cadence")
        XCTAssertEqual(
            ledger.debugRetainedTokenCount(bridgeKey: "bridge-1", scope: composerLedgerScope()),
            0, "deactivation removes every retained non-terminal token")

        // The executing closure later reports at its probe — after
        // deactivation, that report is ignored.
        ledger.cancelled(executing, at: 11.0, attemptedOperations: 3, failures: 1)
        ledger.completed(executing, at: 11.1, attemptedOperations: 3, failures: 0)
        XCTAssertEqual(snap(ledger), .empty)
    }

    func testLedgerDeactivateSessionWithStaleGenerationIsANoOp() {
        var ledger = beganLedger(generation: 2)

        // Work from generation 1 outlived a restart and deactivates late — it
        // must not kill the successor session.
        ledger.deactivateSession(
            bridgeKey: "bridge-1", scope: composerLedgerScope(), generation: 1)

        let current = ledgerToken(generation: 2, sequence: 1)
        ledger.enqueued(current, at: 10.0)
        XCTAssertEqual(snap(ledger).enqueuedItems, 1,
            "the generation-2 session survived the stale deactivation")
    }

    func testLedgerIgnoresCompletedBeforeStarted() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)
        ledger.enqueued(t, at: 10.0)

        ledger.completed(t, at: 10.1, attemptedOperations: 5, failures: 0)
        XCTAssertEqual(snap(ledger).successfulItems, 0,
            "completed is accepted only from the started state")

        // The invalid report did not consume the token — the honest sequence
        // still works.
        ledger.started(t, at: 10.2)
        ledger.completed(t, at: 10.3, attemptedOperations: 5, failures: 0)
        let snapshot = snap(ledger)
        XCTAssertEqual(snapshot.successfulItems, 1)
        XCTAssertEqual(snapshot.attemptedOperations, 5,
            "the ignored report contributed nothing; only the valid one counted")
    }

    func testLedgerIgnoresSupersededAfterStarted() {
        var ledger = beganLedger()
        let t = ledgerToken(sequence: 1)
        ledger.enqueued(t, at: 10.0)
        ledger.started(t, at: 10.1)

        // A started item has left the pending slot — nothing replaced it.
        ledger.superseded(t)
        XCTAssertEqual(snap(ledger).supersededItems, 0,
            "superseded is accepted only from the enqueued state")

        ledger.completed(t, at: 10.2, attemptedOperations: 1, failures: 0)
        XCTAssertEqual(snap(ledger).successfulItems, 1,
            "the invalid supersession did not consume the token")
    }

    func testLedgerIgnoresEveryEventForAbsentOrSessionlessTokens() {
        var ledger = beganLedger()
        let never = ledgerToken(sequence: 99)
        ledger.started(never, at: 10.0)
        ledger.completed(never, at: 10.1, attemptedOperations: 5, failures: 0)
        ledger.cancelled(never, at: 10.2, attemptedOperations: 5, failures: 0)
        ledger.superseded(never)
        XCTAssertEqual(snap(ledger), .empty, "no event was ever admitted")

        // No beginSession at all: even enqueued is ignored.
        var coldLedger = CompositionSendLedger()
        coldLedger.enqueued(ledgerToken(sequence: 1), at: 10.0)
        XCTAssertEqual(snap(coldLedger), .empty)
    }

    // MARK: Isolation

    func testLedgerSessionsAreIsolatedByBridgeKeyAndScope() {
        var ledger = beganLedger(bridge: "bridge-1")
        ledger.beginSession(
            bridgeKey: "bridge-2", scope: composerLedgerScope(), generation: 1)
        ledger.beginSession(
            bridgeKey: "bridge-1",
            scope: RestScope(roomID: "room-a", owner: .studio), generation: 1)

        completeContributingItem(in: &ledger, sequence: 1, finishedAt: 1.0)
        completeContributingItem(in: &ledger, sequence: 2, finishedAt: 2.0)

        XCTAssertEqual(snap(ledger, asOf: 2.0).successfulItems, 2)
        XCTAssertEqual(snap(ledger, bridge: "bridge-2", asOf: 2.0), .empty,
            "the same roomID on another bridge shares nothing")
        XCTAssertEqual(
            ledger.snapshot(
                bridgeKey: "bridge-1",
                scope: RestScope(roomID: "room-a", owner: .studio), asOf: 2.0),
            .empty,
            "the .studio owner on the same room and bridge is a different session")
    }

    // MARK: Packet 4 ledger support

    private func composerLedgerScope(_ roomID: String = "room-a") -> RestScope {
        RestScope(roomID: roomID, owner: .composer)
    }

    private func ledgerToken(
        bridge: String = "bridge-1",
        roomID: String = "room-a",
        generation: Int = 1,
        sequence: UInt64
    ) -> CompositionSendLedger.Token {
        CompositionSendLedger.Token(
            bridgeKey: bridge,
            scope: composerLedgerScope(roomID),
            generation: generation,
            sequence: sequence)
    }

    private func beganLedger(
        bridge: String = "bridge-1",
        roomID: String = "room-a",
        generation: Int = 1
    ) -> CompositionSendLedger {
        var ledger = CompositionSendLedger()
        ledger.beginSession(
            bridgeKey: bridge, scope: composerLedgerScope(roomID), generation: generation)
        return ledger
    }

    private func snap(
        _ ledger: CompositionSendLedger,
        bridge: String = "bridge-1",
        roomID: String = "room-a",
        asOf: CFAbsoluteTime = 100.0
    ) -> CompositionSendLedger.Snapshot {
        ledger.snapshot(bridgeKey: bridge, scope: composerLedgerScope(roomID), asOf: asOf)
    }

    /// Full honest lifecycle for one fully successful single-operation item,
    /// terminal at `finishedAt` — the shorthand the cadence and bounded-memory
    /// tests need.
    private func completeContributingItem(
        in ledger: inout CompositionSendLedger,
        sequence: UInt64,
        finishedAt: CFAbsoluteTime
    ) {
        let t = ledgerToken(sequence: sequence)
        ledger.enqueued(t, at: finishedAt - 0.002)
        ledger.started(t, at: finishedAt - 0.001)
        ledger.completed(t, at: finishedAt, attemptedOperations: 1, failures: 0)
    }
}
