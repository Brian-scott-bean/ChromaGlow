// HueTokensTests.swift
// HueHome Pro — Unit Tests
// Tests for design token correctness — colors, spacing, radii, animations.
// All run fully offline, no device or Bridge required.

import XCTest
import SwiftUI
@testable import HueHome

final class HueTokensTests: XCTestCase {

    // MARK: - Hit Targets

    /// Apple HIG floor — chip rows, mixer transport, and swatch hit areas all
    /// derive from this token; it must never drop below 44.
    func testHitTargetFloor() {
        XCTAssertGreaterThanOrEqual(HueHit.min, 44)
    }

    /// The Round-C terminology contract: TransportVocabulary is the single
    /// source of play-mode words, and none of them may be developer jargon.
    /// (Scripts/hardening_guards.sh Guard 6 covers the view files; this
    /// covers the vocabulary itself in every suite run.)
    func testTransportVocabularyStaysJargonFree() {
        let banned = ["REST", "Transport", "transport", "ENT AREA",
                      "grouped light", "DTLS", "SSE", "rate-capped"]
        let strings: [String] = [
            TransportVocabulary.streamingMenuLabel,
            TransportVocabulary.roomOnlyMenuLabel,
            TransportVocabulary.autoTitle,
            TransportVocabulary.streamingTitle,
            TransportVocabulary.roomOnlyTitle,
            TransportVocabulary.streamingSubtitle,
            TransportVocabulary.roomModeSubtitle,
            TransportVocabulary.streamingSegment,
            TransportVocabulary.roomSegment,
            TransportVocabulary.badgeStreaming,
            TransportVocabulary.badgeRoom,
            TransportVocabulary.badgeBridge,
            TransportVocabulary.playModeSection,
            TransportVocabulary.choosePlayTitle,
            TransportVocabulary.choosePlayMessage,
            TransportVocabulary.saveSheetFooter,
            TransportVocabulary.applyWithMenu,
            TransportVocabulary.preferredMenu,
            TransportVocabulary.bridgeStoredStatus,
            TransportVocabulary.fallbackStatus,
            TransportVocabulary.roomModeCadenceStatus(liveSeconds: nil),
            TransportVocabulary.roomModeCadenceStatus(liveSeconds: 1.2),
            TransportVocabulary.roomModeRotationStatus,
            TransportVocabulary.toastStreaming,
            TransportVocabulary.toastRoomMode,
            TransportVocabulary.toastOneShot,
        ] + packet5RoomModeStatuses
        for s in strings {
            for b in banned {
                XCTAssertFalse(s.contains(b),
                               "vocabulary string \"\(s)\" contains banned word \"\(b)\"")
            }
        }
    }

    /// Every sentence `roomModeStatus` can produce — the packet-5 copy is a
    /// function, so the guard has to cover its whole output set, not a
    /// constant.
    private var packet5RoomModeStatuses: [String] {
        let reasons: [CompositionFallbackReason?] = [
            nil, .entertainmentUnavailable, .bridgeCapacityInsufficient,
            .bridgeCapacityUnknown, .bridgeStoredUploadFailed,
        ]
        return reasons.flatMap { reason in
            [false, true].flatMap { large in
                [nil, 1.2].map { (seconds: Double?) in
                    TransportVocabulary.roomModeStatus(
                        fallback: reason, largeRoom: large, liveSeconds: seconds)
                }
            }
        }
    }

    /// Packet 5: the transport vocabulary must never state a light count. The
    /// one honest light limit in the product is the bridge-enforced
    /// entertainment-area size shown in EntertainmentConfigBuilderView, and the
    /// bridge-reported capacity figure in the bridge-stored error — neither
    /// lives here, and a "20 lights" sentence would be wrong in every domain.
    func testTransportVocabularyStatesNoLightCount() {
        let all = packet5RoomModeStatuses + [
            TransportVocabulary.roomModeRotationStatus,
            TransportVocabulary.bridgeStoredStatus,
            TransportVocabulary.fallbackStatus,
            TransportVocabulary.choosePlayMessage,
            TransportVocabulary.saveSheetFooter,
        ]
        for s in all {
            XCTAssertNil(try? /\d+ lights?\b/.firstMatch(in: s),
                         "vocabulary string states a light count: \"\(s)\"")
        }
    }

    /// Packet 5: a bare "REST" in the UI layer escaped BOTH existing guards —
    /// this test only iterated TransportVocabulary members, and
    /// hardening_guards.sh Guard 6 greps for "(REST)"/"[REST"/"Runtime-only
    /// REST", none of which matched `STREAMING ONLY — INACTIVE OVER REST`.
    /// Source-inspection closes the gap for every user-facing string literal.
    func testNoBareRESTInUserFacingUIStrings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("HueHome/UI")

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no UI sources to inspect")

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                // Only string literals reach the user.
                guard line.contains("\"") else { continue }
                for match in line.matches(of: /"[^"]*"/) {
                    if match.output.contains("REST") {
                        offenders.append("\(file.lastPathComponent):\(lineNumber + 1) \(match.output)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "\"REST\" is a developer word and must not reach the user:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - Color Hex Init

    func testHexInitSixDigit() {
        let red = Color(hex: "#FF0000")
        // Can't directly inspect Color values in unit tests,
        // but we verify it doesn't crash and resolves to a non-nil UIColor
        let ui = UIColor(red)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 1.0, accuracy: 0.01)
    }

    func testHexInitWithoutHash() {
        let color = Color(hex: "FFC107")
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 255.0/255.0, accuracy: 0.01)
        XCTAssertEqual(g, 193.0/255.0, accuracy: 0.01)
        XCTAssertEqual(b, 7.0/255.0,   accuracy: 0.01)
        XCTAssertEqual(a, 1.0,          accuracy: 0.01)
    }

    func testHexInitThreeDigit() {
        let color = Color(hex: "#F00")
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
    }

    func testHexInitBlack() {
        let color = Color(hex: "#000000")
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
    }

    func testHexInitWhite() {
        let color = Color(hex: "#FFFFFF")
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 1.0, accuracy: 0.01)
        XCTAssertEqual(b, 1.0, accuracy: 0.01)
    }

    // MARK: - Spacing Tokens

    func testSpacingValues() {
        XCTAssertEqual(HueSpacing.xs,      4)
        XCTAssertEqual(HueSpacing.sm,      8)
        XCTAssertEqual(HueSpacing.md,      12)
        XCTAssertEqual(HueSpacing.lg,      16)
        XCTAssertEqual(HueSpacing.xl,      20)
        XCTAssertEqual(HueSpacing.xxl,     24)
        XCTAssertEqual(HueSpacing.section, 32)
        XCTAssertEqual(HueSpacing.cardPad, 16)
        XCTAssertEqual(HueSpacing.screenH, 20)
        XCTAssertEqual(HueSpacing.screenV, 16)
    }

    func testSpacingIsAscending() {
        XCTAssertLessThan(HueSpacing.xs, HueSpacing.sm)
        XCTAssertLessThan(HueSpacing.sm, HueSpacing.md)
        XCTAssertLessThan(HueSpacing.md, HueSpacing.lg)
        XCTAssertLessThan(HueSpacing.lg, HueSpacing.xl)
        XCTAssertLessThan(HueSpacing.xl, HueSpacing.xxl)
        XCTAssertLessThan(HueSpacing.xxl, HueSpacing.section)
    }

    // MARK: - Corner Radius Tokens

    func testRadiusValues() {
        XCTAssertEqual(HueRadius.sm,   8)
        XCTAssertEqual(HueRadius.md,   12)
        XCTAssertEqual(HueRadius.lg,   16)
        XCTAssertEqual(HueRadius.xl,   20)
        XCTAssertEqual(HueRadius.pill, 999)
    }

    func testRadiusIsAscending() {
        XCTAssertLessThan(HueRadius.sm, HueRadius.md)
        XCTAssertLessThan(HueRadius.md, HueRadius.lg)
        XCTAssertLessThan(HueRadius.lg, HueRadius.xl)
        XCTAssertLessThan(HueRadius.xl, HueRadius.pill)
    }

    // MARK: - Shadow Tokens

    func testCardShadowRadius() {
        XCTAssertEqual(HueShadows.card.radius, 8)
        XCTAssertEqual(HueShadows.elevated.radius, 16)
        XCTAssertEqual(HueShadows.modal.radius, 32)
    }

    func testShadowsAscendingRadius() {
        XCTAssertLessThan(HueShadows.card.radius, HueShadows.elevated.radius)
        XCTAssertLessThan(HueShadows.elevated.radius, HueShadows.modal.radius)
    }

    // MARK: - Adaptive Color

    func testAdaptiveColorResolvesDark() {
        let adaptive = HuePalette.Adaptive.background
        let resolved = adaptive.resolve(in: .dark)
        // Should be Noir background — very dark
        let ui = UIColor(resolved)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        // #141414 ≈ 0.078 each channel
        XCTAssertLessThan(r, 0.15)
        XCTAssertLessThan(g, 0.15)
        XCTAssertLessThan(b, 0.15)
    }

    func testAdaptiveColorResolvesLight() {
        let adaptive = HuePalette.Adaptive.background
        let resolved = adaptive.resolve(in: .light)
        // Should be Estate background — light gray
        let ui = UIColor(resolved)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        // #F2F2F7 ≈ 0.949
        XCTAssertGreaterThan(r, 0.85)
        XCTAssertGreaterThan(g, 0.85)
        XCTAssertGreaterThan(b, 0.85)
    }
}
