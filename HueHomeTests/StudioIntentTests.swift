// StudioIntentTests.swift
// ChromaGlow — Siri Shortcuts

import XCTest
@testable import HueHome

@MainActor
final class StudioIntentTests: XCTestCase {

    private func preset(id: UUID = UUID(), name: String = "Test Scene") -> CompositionPreset {
        CompositionPreset(
            id: id, name: name, icon: "sparkles", accentColorHex: "#FFB833",
            isBuiltIn: false, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(), updatedAt: Date()
        )
    }

    // ── Entity mapping ────────────────────────────────────

    func testCompositionEntityMapsIDAndName() {
        let id = UUID()
        let entity = CompositionEntity(preset: preset(id: id, name: "Ocean Waves"))
        XCTAssertEqual(entity.id, id.uuidString)
        XCTAssertEqual(entity.name, "Ocean Waves")
    }

    // ── Eligibility ───────────────────────────────────────

    func testEligibleExcludesStarterDraft() {
        let starter = preset(id: StudioViewModel.composerStarterDraftPresetID, name: "Draft")
        let real    = preset(name: "Real Scene")
        let out = CompositionEntityQuery.eligible([starter, real])
        XCTAssertEqual(out.map(\.name), ["Real Scene"],
                       "the + Create starter draft must never be sayable")
    }

    // ── Pending action semantics ──────────────────────────

    func testRequestStudioActionBumpsOpenToken() {
        let coordinator = DeepLinkCoordinator()
        let before = coordinator.openToken
        let id = UUID()
        coordinator.requestStudioAction(.composition(presetID: id, groupID: "room-1"))
        XCTAssertEqual(coordinator.openToken, before + 1,
                       "observers key on openToken — a request that doesn't bump it is invisible")
        XCTAssertEqual(coordinator.pendingStudioAction,
                       .composition(presetID: id, groupID: "room-1"))
    }

    func testPendingStudioActionEquality() {
        let id = UUID()
        XCTAssertEqual(PendingStudioAction.composition(presetID: id, groupID: "a"),
                       PendingStudioAction.composition(presetID: id, groupID: "a"))
        XCTAssertNotEqual(PendingStudioAction.composition(presetID: id, groupID: "a"),
                          PendingStudioAction.effect(effectID: "candle", groupID: "a"))
    }
}
