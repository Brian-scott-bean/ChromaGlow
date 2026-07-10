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

    // ── SSE staleness (mirek is the CT-mode signal) ───────

    /// A CT-mode light painted a COLOR from outside the app (official Hue
    /// app, a switch): the SSE event carries only `color`. The stale mirek
    /// must be invalidated or capture mis-reads the light as still-CT and
    /// Copy Color grabs warm white instead of the actual color.
    func testCaptureAfterSSEColorOnlyUpdateCopiesTheColorNotStaleMirek() throws {
        let room = RoomDisplayItem(
            kind: .room, id: "room-a", name: "Test Room", archetype: nil,
            isOn: true, brightness: 70, groupedLightID: "gl-a", lightCount: 1,
            bridgeID: "bridge-a", childResourceRefs: [(rid: "light-1", rtype: "light")]
        )
        let vm = RoomDetailViewModel(
            room: room, api: nil, isDemoMode: true,
            initialLights: [light(colorTempMirek: 370)]   // CT mode
        )

        let updates = try JSONDecoder().decode([SSEResourceUpdate].self, from: Data("""
        [{"id": "light-1", "type": "light", "color": {"xy": {"x": 0.42, "y": 0.33}}}]
        """.utf8))
        vm.applySSEUpdates(updates)

        let copied = ColorClipboard.capture(from: vm.lights[0])
        XCTAssertNil(copied?.mirek, "color-only SSE update must clear the stale mirek")
        XCTAssertEqual(copied?.x, 0.42)
        XCTAssertEqual(copied?.y, 0.33)
    }

    /// Same invariant for the orchestrator's per-light cache (HueLight):
    /// `applying` used to carry `color_temperature` over verbatim on a
    /// color-only event, leaving `updateScene`'s CT fallback stale too.
    func testHueLightApplyingColorOnlyUpdateInvalidatesMirek() throws {
        let ctModeLight = try JSONDecoder().decode(HueLight.self, from: Data("""
        {"id": "light-1", "metadata": {"name": "Lamp"},
         "on": {"on": true}, "dimming": {"brightness": 80},
         "color": {"xy": {"x": 0.5, "y": 0.4}},
         "color_temperature": {"mirek": 370,
                               "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 500},
                               "mirek_valid": true}}
        """.utf8))
        let update = try JSONDecoder().decode(SSEResourceUpdate.self, from: Data("""
        {"id": "light-1", "type": "light", "color": {"xy": {"x": 0.42, "y": 0.33}}}
        """.utf8))

        let applied = ctModeLight.applying(sseUpdate: update)

        XCTAssertNil(applied.color_temperature?.mirek,
                     "color-only update = light left CT mode; mirek must clear")
        XCTAssertEqual(applied.color_temperature?.mirek_valid, false)
        XCTAssertEqual(applied.color_temperature?.mirek_schema?.mirek_minimum, 153,
                       "schema is topology-stable — capability range must survive")
        XCTAssertEqual(applied.color?.xy.x, 0.42)

        // And a CT update still round-trips normally.
        let ctUpdate = try JSONDecoder().decode(SSEResourceUpdate.self, from: Data("""
        {"id": "light-1", "type": "light", "color_temperature": {"mirek": 300}}
        """.utf8))
        XCTAssertEqual(applied.applying(sseUpdate: ctUpdate).color_temperature?.mirek, 300)
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
