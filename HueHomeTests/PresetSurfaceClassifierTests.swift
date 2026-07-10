// PresetSurfaceClassifierTests.swift
// ChromaGlow — where a Composer creation belongs
//
// The classifier decides which deck (or tab) a creation appears on, so its
// truth table has to be exact: reactive beats everything (a mic-driven preset
// is live even when its look is static), a still look is a scene, and the
// rest are effects. Also pinned against the real 56-preset catalog so a
// tuning change that silently reclassifies half the built-ins fails a test.

import XCTest
@testable import HueHome

final class PresetSurfaceClassifierTests: XCTestCase {

    private func preset(
        pattern: MotionConfig.Pattern = .static,
        shape: EnvelopeConfig.Shape = .steady,
        source: ReactionConfig.Source = .none
    ) -> CompositionPreset {
        CompositionPreset(
            id: UUID(), name: "T", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .myCreations, seasonMonths: nil,
            palette: PaletteConfig(),
            motion: MotionConfig(pattern: pattern),
            envelope: EnvelopeConfig(shape: shape),
            reaction: ReactionConfig(source: source),
            createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - Truth table

    func testStaticSteadySilentIsAScene() {
        XCTAssertEqual(PresetSurfaceClassifier.surface(for: preset()), .scene)
    }

    func testMotionMakesAnEffect() {
        XCTAssertEqual(PresetSurfaceClassifier.surface(for: preset(pattern: .wave)), .effect)
    }

    func testABreathingEnvelopeAloneMakesAnEffect() {
        // Static position but pulsing brightness — it moves, so it's an effect.
        XCTAssertEqual(PresetSurfaceClassifier.surface(for: preset(shape: .breathe)), .effect)
    }

    func testAnyReactionMakesItLive() {
        for source in ReactionConfig.Source.allCases where source != .none {
            XCTAssertEqual(PresetSurfaceClassifier.surface(for: preset(source: source)), .live,
                           "\(source.rawValue)")
        }
    }

    /// Reaction wins over stillness: the hybrid tier (reactive + static look)
    /// belongs with party/strobe, not with scenes.
    func testAStaticButListeningPresetIsLiveNotScene() {
        let hybrid = preset(pattern: .static, shape: .steady, source: .micBass)
        XCTAssertEqual(hybrid.capabilityTier, .hybrid, "precondition")
        XCTAssertEqual(PresetSurfaceClassifier.surface(for: hybrid), .live)
    }

    /// The classifier's scene case is exactly the bridge-exportable set — a
    /// "scene" the Scenes shelf offers must never be refused by the exporter.
    func testEverySceneClassifiedPresetIsBridgeExportable() {
        for builtIn in CompositionStore.builtInPresets
        where PresetSurfaceClassifier.surface(for: builtIn) == .scene {
            XCTAssertNil(BridgeDynamicSceneExporter.ineligibilityReason(for: builtIn), builtIn.name)
            XCTAssertEqual(builtIn.capabilityTier, .bridgeOptimized, builtIn.name)
        }
    }

    // MARK: - The real catalog

    /// Pin the shipped catalog's distribution. If a preset-tuning change
    /// reclassifies built-ins (say, Deep Focus grows an envelope and stops
    /// being a scene), this fails loudly instead of the deck quietly moving.
    func testShippedCatalogDistributionIsSane() {
        let surfaces = CompositionStore.builtInPresets.map(PresetSurfaceClassifier.surface(for:))

        let scenes = surfaces.filter { $0 == .scene }.count
        let effects = surfaces.filter { $0 == .effect }.count
        let live = surfaces.filter { $0 == .live }.count

        XCTAssertEqual(scenes + effects + live, CompositionStore.builtInPresets.count,
                       "every preset classifies")
        // The catalog ships four static + steady + silent presets
        // (Amber Evening, Reading Nook, Deep Focus, Energize).
        XCTAssertEqual(scenes, 4, "expected exactly the four static built-ins as scenes")
        XCTAssertGreaterThan(effects, 40, "the bulk of the catalog moves")
    }
}
