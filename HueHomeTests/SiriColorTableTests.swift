// SiriColorTableTests.swift
// ChromaGlow — Siri Shortcuts

import XCTest
@testable import HueHome

final class SiriColorTableTests: XCTestCase {

    /// Every chromatic payload is already gamut-C legal: re-clamping must
    /// not move it. Saturated yellows project ONTO the red–green gamut edge,
    /// and re-projecting an edge point drifts by one ulp — so the bar is
    /// FP-noise stability (1e-9), not bit-exactness.
    func testEveryChromaticColorIsStableUnderGamutClamp() {
        for choice in NamedColorChoice.allCases where SiriColorTable.whites[choice] == nil {
            guard case .xy(let x, let y) = SiriColorTable.payload(for: choice) else {
                XCTFail("\(choice.rawValue) should produce an xy payload")
                continue
            }
            let clamped = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: .c)
            XCTAssertEqual(clamped.x, x, accuracy: 1e-9,
                           "\(choice.rawValue) x moved under clamp — outside gamut C")
            XCTAssertEqual(clamped.y, y, accuracy: 1e-9,
                           "\(choice.rawValue) y moved under clamp — outside gamut C")
        }
    }

    func testEveryWhiteIsInsideHueMirekRange() {
        for choice in NamedColorChoice.allCases {
            guard case .mirek(let mirek) = SiriColorTable.payload(for: choice) else { continue }
            XCTAssertTrue((153...500).contains(mirek),
                          "\(choice.rawValue) mirek \(mirek) outside 153–500")
        }
    }

    func testEveryCaseHasExactlyOneDefinition() {
        for choice in NamedColorChoice.allCases {
            let inChromatic = SiriColorTable.chromatic[choice] != nil
            let inWhites    = SiriColorTable.whites[choice] != nil
            XCTAssertTrue(inChromatic != inWhites,
                          "\(choice.rawValue) must be defined exactly once (chromatic XOR white)")
        }
    }

    func testEveryCaseHasDisplayRepresentation() {
        for choice in NamedColorChoice.allCases {
            XCTAssertNotNil(NamedColorChoice.caseDisplayRepresentations[choice],
                            "\(choice.rawValue) missing a display name")
        }
    }

    func testWarmAndCoolWhitesAreOrderedByWarmth() {
        // Higher mirek = warmer. The names must not lie.
        guard case .mirek(let daylight) = SiriColorTable.payload(for: .daylight),
              case .mirek(let cool)     = SiriColorTable.payload(for: .coolWhite),
              case .mirek(let neutral)  = SiriColorTable.payload(for: .neutralWhite),
              case .mirek(let soft)     = SiriColorTable.payload(for: .softWhite),
              case .mirek(let warm)     = SiriColorTable.payload(for: .warmWhite) else {
            return XCTFail("whites must all be mirek payloads")
        }
        XCTAssertTrue(daylight < cool && cool < neutral && neutral < soft && soft < warm)
    }
}
