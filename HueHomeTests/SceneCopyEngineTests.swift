// SceneCopyEngineTests.swift
// ChromaGlow — Scenes overhaul Phase 5
//
// Deterministic remapping: recipe extraction/order, round-robin vs sampled
// distribution, capability downgrades, gamut clamping, dynamic-palette
// passthrough, all-off copies, and the verbatim move-undo rebuild.

import XCTest
@testable import HueHome

final class SceneCopyEngineTests: XCTestCase {

    // ── Fixtures ──────────────────────────────────────────

    private func action(
        rid: String,
        on: Bool = true,
        brightness: Double? = 80,
        x: Double? = nil,
        y: Double? = nil,
        mirek: Int? = nil
    ) -> SceneActionDetail {
        SceneActionDetail(
            target: SceneActionTarget(rid: rid, rtype: "light"),
            action: SceneActionState(
                on: SceneActionOn(on: on),
                dimming: brightness.map { SceneActionDimming(brightness: $0) },
                color: (x != nil && y != nil)
                    ? SceneActionColor(xy: .init(x: x!, y: y!)) : nil,
                color_temperature: mirek.map { SceneActionCT(mirek: $0) }
            )
        )
    }

    private func detail(
        actions: [SceneActionDetail],
        palette: ScenePaletteDetail? = nil,
        speed: Double? = nil,
        autoDynamic: Bool? = nil
    ) -> HueSceneDetail {
        HueSceneDetail(
            id: "scene-src",
            metadata: SceneMetadata(name: "Source Scene"),
            group: SceneGroup(rid: "room-src", rtype: "room"),
            actions: actions,
            palette: palette,
            speed: speed,
            auto_dynamic: autoDynamic
        )
    }

    private func light(
        id: String,
        name: String,
        color: Bool,
        ct: Bool,
        gamut: String? = "C",
        mirekMax: Int = 454
    ) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: name, archetype: nil),
            on: OnState(on: false),
            dimming: DimmingState(brightness: 50),
            color: color ? LightColor(xy: CIExy(x: 0.3, y: 0.3), gamut_type: gamut) : nil,
            color_temperature: ct
                ? LightColorTemp(mirek: 300,
                                 mirek_schema: MirekSchema(mirek_minimum: 153,
                                                           mirek_maximum: mirekMax),
                                 mirek_valid: true)
                : nil,
            owner: nil
        )
    }

    // ── Distribution ──────────────────────────────────────

    func testMoreRecipesThanLights_evenlySpacedSampleKeepsExtremes() {
        // 5 distinct CT recipes; sort order is warm→cool (mirek desc).
        let src = detail(actions: [153, 200, 300, 400, 500].map {
            action(rid: "src-\($0)", mirek: $0)
        })
        let targets = ["a", "b", "c"].map { light(id: $0, name: $0, color: false, ct: true, mirekMax: 500) }

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: targets)

        // Sample indices i*5/3 = 0, 1, 3 over [500, 400, 300, 200, 153].
        XCTAssertEqual(remapped.map(\.mirek), [500, 400, 200],
                       "a 5-look palette on 3 lights must keep its extremes")
    }

    func testFewerRecipesThanLights_cyclesRoundRobin() {
        let src = detail(actions: [
            action(rid: "s1", mirek: 400),
            action(rid: "s2", mirek: 200),
        ])
        let targets = ["a", "b", "c", "d", "e", "f"].map {
            light(id: $0, name: $0, color: false, ct: true, mirekMax: 500)
        }

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: targets)
        XCTAssertEqual(remapped.map(\.mirek), [400, 200, 400, 200, 400, 200])
    }

    func testTargetsSortByNameForDeterminism() {
        let src = detail(actions: [action(rid: "s1", mirek: 400),
                                   action(rid: "s2", mirek: 200)])
        let targets = [
            light(id: "L2", name: "Zed",   color: false, ct: true, mirekMax: 500),
            light(id: "L1", name: "Alpha", color: false, ct: true, mirekMax: 500),
        ]
        let remapped = SceneCopyEngine.remap(detail: src, targetLights: targets)
        XCTAssertEqual(remapped.map(\.lightName), ["Alpha", "Zed"])
        XCTAssertEqual(remapped.map(\.mirek), [400, 200])
    }

    // ── Capability downgrades ─────────────────────────────

    func testColorRecipeOnCTOnlyLightApproximatesCT() {
        let src = detail(actions: [action(rid: "s1", x: 0.68, y: 0.31)])   // warm red
        let target = light(id: "ct1", name: "Ambiance", color: false, ct: true, mirekMax: 454)

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: [target])
        XCTAssertEqual(remapped.count, 1)
        XCTAssertEqual(remapped[0].downgrade, .ctApproximation)
        XCTAssertNil(remapped[0].x)
        let mirek = try! XCTUnwrap(remapped[0].mirek)
        XCTAssertTrue((153...454).contains(mirek),
                      "approximated CT must clamp into the light's schema range")
    }

    func testColorRecipeOnDimmableOnlyLightFallsBackToBrightness() {
        let src = detail(actions: [action(rid: "s1", brightness: 63, x: 0.2, y: 0.6)])
        let target = light(id: "d1", name: "Dimmer", color: false, ct: false)

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: [target])
        XCTAssertEqual(remapped[0].downgrade, .brightnessOnly)
        XCTAssertNil(remapped[0].x)
        XCTAssertNil(remapped[0].mirek)
        XCTAssertEqual(remapped[0].brightness, 63)
    }

    func testOutOfGamutColorClampsToTargetGamut() {
        // (0.75, 0.22) lies outside gamut C's red corner (0.692, 0.308).
        let src = detail(actions: [action(rid: "s1", x: 0.75, y: 0.22)])
        let target = light(id: "c1", name: "ColorBulb", color: true, ct: false)

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: [target])
        let x = try! XCTUnwrap(remapped[0].x)
        let y = try! XCTUnwrap(remapped[0].y)
        XCTAssertFalse(x == 0.75 && y == 0.22, "out-of-gamut xy must be clamped")
        // Clamping is idempotent — the result is already inside the triangle.
        let again = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: .c)
        XCTAssertEqual(again.x, x, accuracy: 0.0001)
        XCTAssertEqual(again.y, y, accuracy: 0.0001)
    }

    func testCTRecipeClampsIntoTargetSchema() {
        let src = detail(actions: [action(rid: "s1", mirek: 500)])
        let target = light(id: "ct1", name: "Ambiance", color: false, ct: true, mirekMax: 454)
        let remapped = SceneCopyEngine.remap(detail: src, targetLights: [target])
        XCTAssertEqual(remapped[0].mirek, 454)
        XCTAssertNil(remapped[0].downgrade)
    }

    // ── Edge cases ────────────────────────────────────────

    func testAllOffSceneCopiesAsAllOff() {
        let src = detail(actions: [
            action(rid: "s1", on: false, brightness: nil),
            action(rid: "s2", on: false, brightness: nil),
        ])
        let targets = ["a", "b", "c"].map { light(id: $0, name: $0, color: true, ct: true) }

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: targets)
        XCTAssertEqual(remapped.count, 3)
        XCTAssertTrue(remapped.allSatisfy { !$0.on })
    }

    func testDuplicateRecipesCollapse() {
        // Three identical actions = ONE recipe → every target gets it.
        let src = detail(actions: (1...3).map { action(rid: "s\($0)", mirek: 300) })
        XCTAssertEqual(SceneCopyEngine.recipes(from: src.actions!).count, 1)
    }

    // ── Request assembly ──────────────────────────────────

    func testDynamicPalettePassesThroughVerbatim() {
        let palette = ScenePaletteDetail(
            color: [
                .init(color: SceneActionColor(xy: .init(x: 0.2, y: 0.3)),
                      dimming: SceneActionDimming(brightness: 70)),
                .init(color: SceneActionColor(xy: .init(x: 0.5, y: 0.4)),
                      dimming: SceneActionDimming(brightness: 70)),
            ],
            dimming: [SceneActionDimming(brightness: 70)]
        )
        let src = detail(actions: [action(rid: "s1", x: 0.2, y: 0.3)],
                         palette: palette, speed: 0.7, autoDynamic: true)
        let target = light(id: "c1", name: "ColorBulb", color: true, ct: false)

        let remapped = SceneCopyEngine.remap(detail: src, targetLights: [target])
        let request = SceneCopyEngine.request(
            name: "Copy", targetGroupID: "room-dst", targetRtype: "room",
            remapped: remapped, detail: src
        )

        XCTAssertEqual(request.palette?.color.count, 2,
                       "the dynamic palette is scene-level and must copy as-is")
        XCTAssertEqual(request.speed, 0.7)
        XCTAssertEqual(request.auto_dynamic, true)
        XCTAssertEqual(request.group.rid, "room-dst")
    }

    func testRecreateRequestRebuildsOriginalVerbatim() {
        let src = detail(actions: [
            action(rid: "orig-1", brightness: 40, x: 0.31, y: 0.32),
            action(rid: "orig-2", brightness: 90, mirek: 366),
            action(rid: "orig-3", on: false, brightness: nil),
        ])
        let request = SceneCopyEngine.recreateRequest(detail: src)

        XCTAssertEqual(request.metadata.name, "Source Scene")
        XCTAssertEqual(request.group.rid, "room-src")
        XCTAssertEqual(request.actions.count, 3)
        XCTAssertEqual(request.actions[0].target.rid, "orig-1")
        XCTAssertEqual(request.actions[0].action.color?.xy.x ?? -1, 0.31, accuracy: 0.0001)
        XCTAssertEqual(request.actions[1].action.color_temperature?.mirek, 366)
        XCTAssertEqual(request.actions[2].action.on?.on, false)
    }
}
