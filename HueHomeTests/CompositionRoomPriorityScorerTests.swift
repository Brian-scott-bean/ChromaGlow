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
}
