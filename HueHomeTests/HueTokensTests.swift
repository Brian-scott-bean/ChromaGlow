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
