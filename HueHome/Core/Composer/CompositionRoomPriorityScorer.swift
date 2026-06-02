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
