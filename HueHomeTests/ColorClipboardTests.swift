// ColorClipboardTests.swift
// ChromaGlow — light-card color copy/paste

import XCTest
@testable import HueHome

@MainActor
final class ColorClipboardTests: XCTestCase {

    private func light(
        isOn: Bool = true,
        brightness: Double = 80,
        colorX: Double? = nil,
        colorY: Double? = nil,
        colorTempMirek: Int? = nil,
        mirekMin: Int = 153,
        mirekMax: Int = 500
    ) -> LightDisplayItem {
        LightDisplayItem(
            id: "light-1", name: "Test Light", archetype: nil,
            isOn: isOn, brightness: brightness,
            colorX: colorX, colorY: colorY,
            colorTempMirek: colorTempMirek,
            mirekMin: mirekMin, mirekMax: mirekMax
        )
    }

    // ── Capture rules ─────────────────────────────────────

    func testCaptureCTModeLightCopiesMirekAndBrightness() {
        let copied = ColorClipboard.capture(from: light(brightness: 45, colorTempMirek: 370))
        XCTAssertEqual(copied?.mirek, 370)
        XCTAssertEqual(copied?.brightness, 45)
        XCTAssertNil(copied?.x)
        XCTAssertNil(copied?.y)
    }

    func testCaptureColorModeLightCopiesXY() {
        let copied = ColorClipboard.capture(from: light(colorX: 0.42, colorY: 0.33))
        XCTAssertEqual(copied?.x, 0.42)
        XCTAssertEqual(copied?.y, 0.33)
        XCTAssertNil(copied?.mirek)
    }

    func testCaptureCTModePrefersMirekOverStaleXY() {
        // The bridge nulls mirek while a light renders xy color, so a
        // non-nil mirek means CT mode — the xy the model still carries
        // is stale and must lose.
        let copied = ColorClipboard.capture(
            from: light(colorX: 0.42, colorY: 0.33, colorTempMirek: 300)
        )
        XCTAssertEqual(copied?.mirek, 300)
        XCTAssertNil(copied?.x)
        XCTAssertNil(copied?.y)
    }

    func testCaptureDimmableOnlyReturnsNil() {
        // A brightness-only copy is not a color — Copy/Save hide instead.
        XCTAssertNil(ColorClipboard.capture(from: light(mirekMin: 153, mirekMax: 153)))
    }

    func testCaptureOffLightUsesLastKnownValues() {
        let copied = ColorClipboard.capture(
            from: light(isOn: false, brightness: 60, colorX: 0.5, colorY: 0.4)
        )
        XCTAssertEqual(copied?.x, 0.5)
        XCTAssertEqual(copied?.brightness, 60,
                       "an off light copies what it looks like when on")
    }

    // ── Clipboard semantics ───────────────────────────────

    func testCopyStoreClearRoundTrip() {
        let clipboard = ColorClipboard()
        XCTAssertFalse(clipboard.hasColor)

        let swatch = SavedColor(x: 0.3, y: 0.3, brightness: 100)
        clipboard.copy(swatch)
        XCTAssertTrue(clipboard.hasColor)
        XCTAssertEqual(clipboard.copied, swatch)

        let replacement = SavedColor(mirek: 450, brightness: 20)
        clipboard.copy(replacement)
        XCTAssertEqual(clipboard.copied, replacement,
                       "a new copy replaces the old one")

        clipboard.clear()
        XCTAssertFalse(clipboard.hasColor)
        XCTAssertNil(clipboard.copied)
    }
}
