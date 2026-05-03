// HapticManager.swift
// CastChroma — Epic 2 / Story 2.1
//
// Thin wrapper over UIKit feedback generators.
// Pre-warmed via prepare() calls for zero-latency on first fire.
// Story 2.2 will call these from drag gesture handlers.

import UIKit

final class HapticManager: @unchecked Sendable {

    static let shared = HapticManager()
    private init() {}

    // MARK: - Impact

    /// Light tap — used on Toggle flip.
    func light() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    /// Medium impact — used when brightness threshold crossed.
    func medium() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }

    /// Heavy impact — used on drag gesture commit.
    func heavy() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.impactOccurred()
    }

    /// Soft tick — used for incremental brightness notches during drag.
    func soft() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.impactOccurred()
    }

    // MARK: - Notification

    func success() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
    }

    func warning() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.warning)
    }

    func error() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.error)
    }

    // MARK: - Selection

    /// Fine-grained tick — used during colour wheel drag in Story 2.2.
    func selection() {
        let g = UISelectionFeedbackGenerator()
        g.selectionChanged()
    }
}
