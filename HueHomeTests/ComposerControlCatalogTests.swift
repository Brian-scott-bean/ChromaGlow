// ComposerControlCatalogTests.swift
// HueHome Pro — Unit Tests
//
// Locks the composer progressive-disclosure catalog: essential density stays
// scannable across every layer state, gated no-op controls never render, and
// the audit's gap-fix controls (temperature, smoothing, spectrum saturation)
// each appear exactly once.

import XCTest
@testable import HueHome

final class ComposerControlCatalogTests: XCTestCase {

    private let allModes = PaletteConfig.Mode.allCases
    private let allPatterns = MotionConfig.Pattern.allCases
    private let allShapes = EnvelopeConfig.Shape.allCases
    private let allSources = ReactionConfig.Source.allCases

    private func essentials(_ tab: CompositionLayerTab,
                            mode: PaletteConfig.Mode = .gradient,
                            pattern: MotionConfig.Pattern = .cascade,
                            shape: EnvelopeConfig.Shape = .breathe,
                            source: ReactionConfig.Source = .none) -> [String] {
        ComposerControlCatalog.essentialControlIDs(
            tab: tab, paletteMode: mode, motionPattern: pattern,
            envelopeShape: shape, reactionSource: source)
    }

    private func advanced(_ tab: CompositionLayerTab,
                          mode: PaletteConfig.Mode = .gradient,
                          pattern: MotionConfig.Pattern = .cascade,
                          shape: EnvelopeConfig.Shape = .breathe,
                          source: ReactionConfig.Source = .none) -> [String] {
        ComposerControlCatalog.supportingControlIDs(
            tab: tab, paletteMode: mode, motionPattern: pattern,
            envelopeShape: shape, reactionSource: source)
    }

    // ── Density (COMPOSER_SPEC: 3-5 essentials inline; fewer only when
    //    gating removes engine no-ops) ─────────────────────────

    func testEssentialDensityStaysScannableAcrossAllStates() {
        for tab in CompositionLayerTab.allCases {
            for mode in allModes {
                for pattern in allPatterns {
                    for shape in allShapes {
                        for source in allSources {
                            let ids = essentials(tab, mode: mode, pattern: pattern,
                                                 shape: shape, source: source)
                            XCTAssertTrue((1...5).contains(ids.count),
                                          "\(tab) \(mode)/\(pattern)/\(shape)/\(source): \(ids.count)")
                            XCTAssertEqual(ids.count, Set(ids).count, "\(tab) duplicate ids")
                        }
                    }
                }
            }
        }
    }

    func testDefaultStateHasThreeEssentialsPerLayerBase() {
        XCTAssertEqual(essentials(.palette), ["mode", "colorPad", "harmony"])
        XCTAssertEqual(essentials(.motion), ["pattern", "speed", "forward"])
        XCTAssertEqual(essentials(.envelope), ["shape", "bpm", "depth"])
        XCTAssertEqual(essentials(.reaction), ["source"])
    }

    // ── Gating mirrors the engine ─────────────────────────────

    /// .static returns a fixed phase — every motion control is a no-op.
    func testStaticPatternGatesAllMotionControls() {
        XCTAssertEqual(essentials(.motion, pattern: .static), ["pattern"])
        XCTAssertEqual(advanced(.motion, pattern: .static), [])
    }

    /// Scatter/twinkle hash per-light — direction/forward/mirror are no-ops.
    func testNonSpatialPatternsGateDirectionForwardMirror() {
        for pattern in [MotionConfig.Pattern.scatter, .twinkle] {
            XCTAssertFalse(essentials(.motion, pattern: pattern).contains("forward"), "\(pattern)")
            let adv = advanced(.motion, pattern: pattern)
            XCTAssertFalse(adv.contains("direction"), "\(pattern)")
            XCTAssertFalse(adv.contains("mirror"), "\(pattern)")
            XCTAssertTrue(adv.contains("spread") && adv.contains("offset"), "\(pattern)")
        }
    }

    /// .steady returns maxBrightness only.
    func testSteadyShapeGatesBpmDepthMin() {
        XCTAssertEqual(essentials(.envelope, shape: .steady), ["shape"])
        XCTAssertEqual(advanced(.envelope, shape: .steady), ["maxBrightness"])
    }

    /// Sensitivity/threshold/smoothing shape the mic drive only; beat/onset
    /// feel is owned by punchDecay in the beat panel.
    func testReactionControlsGateBySourceKind() {
        for source in [ReactionConfig.Source.micAmplitude, .micBass, .micMid, .micTreble] {
            XCTAssertTrue(essentials(.reaction, source: source).contains("sensitivity"), "\(source)")
            XCTAssertEqual(advanced(.reaction, source: source), ["smoothing", "threshold", "intensity"])
        }
        for source in [ReactionConfig.Source.beat, .onset, .tapTempo] {
            XCTAssertFalse(essentials(.reaction, source: source).contains("sensitivity"), "\(source)")
            XCTAssertTrue(essentials(.reaction, source: source).contains("beatPanel"), "\(source)")
            XCTAssertEqual(advanced(.reaction, source: source), ["intensity"])
        }
        XCTAssertEqual(advanced(.reaction, source: .none), [])
    }

    // ── Gap fixes appear exactly once ─────────────────────────

    func testTemperatureAndSmoothingAppearExactlyOnce() {
        // Temperature: essential in temperature mode, nowhere else.
        XCTAssertTrue(essentials(.palette, mode: .temperature).contains("temperature"))
        XCTAssertFalse(essentials(.palette, mode: .temperature).contains("colorPad"))
        XCTAssertFalse(advanced(.palette, mode: .temperature).contains("temperature"))
        for mode in [PaletteConfig.Mode.solid, .gradient, .spectrum] {
            XCTAssertFalse(essentials(.palette, mode: mode).contains("temperature"), "\(mode)")
        }

        // Smoothing: advanced for mic sources only.
        XCTAssertEqual(advanced(.reaction, source: .micBass).filter { $0 == "smoothing" }.count, 1)
        XCTAssertFalse(essentials(.reaction, source: .micBass).contains("smoothing"))
        XCTAssertFalse(advanced(.reaction, source: .beat).contains("smoothing"))

        // Spectrum saturation: advanced in spectrum mode only.
        XCTAssertTrue(advanced(.palette, mode: .spectrum).contains("saturation"))
        XCTAssertFalse(advanced(.palette, mode: .gradient).contains("saturation"))
    }

    /// Essential and supporting sets never overlap for any state.
    func testEssentialAndSupportingAreDisjoint() {
        for tab in CompositionLayerTab.allCases {
            for mode in allModes {
                for pattern in allPatterns {
                    for shape in allShapes {
                        for source in allSources {
                            let e = Set(essentials(tab, mode: mode, pattern: pattern, shape: shape, source: source))
                            let a = Set(advanced(tab, mode: mode, pattern: pattern, shape: shape, source: source))
                            XCTAssertTrue(e.isDisjoint(with: a),
                                          "\(tab): \(e.intersection(a))")
                        }
                    }
                }
            }
        }
    }

    // ── Labels ────────────────────────────────────────────────

    /// Offset means head count for chase and sparkle density for twinkle.
    func testOffsetLabelIsContextual() {
        XCTAssertEqual(ComposerControlCatalog.offsetLabel(for: .chase), "Heads")
        XCTAssertEqual(ComposerControlCatalog.offsetLabel(for: .twinkle), "Density")
        XCTAssertEqual(ComposerControlCatalog.offsetLabel(for: .wave), "Offset")
    }
}
