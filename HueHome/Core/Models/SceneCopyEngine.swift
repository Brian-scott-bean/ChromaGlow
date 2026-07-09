// SceneCopyEngine.swift
// ChromaGlow — Scenes overhaul Phase 5
//
// Pure remapping engine for copying a scene to another room/zone (possibly
// on another bridge). Hue has no move API — scene.group is create-only and
// actions target absolute light rids — so a "copy" is: fetch the source
// scene's stored actions, remap them onto the target group's lights, and
// POST a brand-new scene. All logic here is value-in/value-out and
// unit-tested; the orchestrator only does I/O around it.
//
// Remapping strategy (deterministic):
//   1. Distinct ON looks ("recipes") are extracted from the source actions
//      and sorted: colors by hue angle, then CT recipes warm→cool, so the
//      palette keeps its visual order on the new lights.
//   2. Target lights sort by name (stable).
//   3. More lights than recipes → recipes cycle round-robin (palette
//      spread). More recipes than lights → evenly-spaced sample, keeping
//      the extremes of a big palette on a small room.
//   4. Per-light capability downgrade: color-capable → gamut-clamped xy;
//      CT-only → mirek (a color recipe approximates via McCamy CCT);
//      dimmable-only → on/brightness.
//   5. All-off source scenes copy as all-off. Dynamic palettes are
//      scene-level, not per-light — they copy verbatim.

import Foundation

enum SceneCopyEngine {

    // ── Recipe: one distinct look from the source scene ───

    struct Recipe: Equatable {
        var brightness: Double?
        var x: Double?
        var y: Double?
        var mirek: Int?

        var isColor: Bool { x != nil && y != nil }
    }

    /// How a recipe was adapted to a target light — surfaced as a badge in
    /// the copy sheet's preview.
    enum Downgrade: Equatable {
        case ctApproximation    // color recipe on a CT-only light (McCamy)
        case brightnessOnly     // recipe had color/CT the light can't show
    }

    /// One row of the copy preview AND the seed for the POST body.
    struct RemappedAction: Equatable {
        let lightID: String
        let lightName: String
        let on: Bool
        let brightness: Double?
        let x: Double?
        let y: Double?
        let mirek: Int?
        let downgrade: Downgrade?
    }

    // ── Recipe extraction ─────────────────────────────────

    /// Distinct ON looks from the source actions, sorted color-by-hue then
    /// CT-warm→cool. OFF actions contribute no recipe (an all-off scene
    /// yields an empty list → the copy is all-off).
    static func recipes(from actions: [SceneActionDetail]) -> [Recipe] {
        var seen: [Recipe] = []
        for action in actions {
            let state = action.action
            guard state.on?.on ?? true else { continue }
            let recipe = Recipe(
                brightness: state.dimming?.brightness,
                x: state.color?.xy?.x,
                y: state.color?.xy?.y,
                mirek: state.color_temperature?.mirek
            )
            // A recipe with no color, no CT and no brightness carries no look.
            guard recipe.isColor || recipe.mirek != nil || recipe.brightness != nil else { continue }
            if !seen.contains(recipe) { seen.append(recipe) }
        }
        return seen.sorted(by: recipeOrder)
    }

    private static func recipeOrder(_ a: Recipe, _ b: Recipe) -> Bool {
        switch (a.isColor, b.isColor) {
        case (true, false): return true          // colors before CT/brightness
        case (false, true): return false
        case (true, true):
            let ha = HueColorUtils.hsb(fromX: a.x!, y: a.y!, brightness: 100).h
            let hb = HueColorUtils.hsb(fromX: b.x!, y: b.y!, brightness: 100).h
            return ha < hb
        case (false, false):
            // CT recipes warm→cool (higher mirek = warmer); pure-brightness last.
            switch (a.mirek, b.mirek) {
            case let (ma?, mb?): return ma > mb
            case (_?, nil):      return true
            case (nil, _?):      return false
            default:             return (a.brightness ?? 0) > (b.brightness ?? 0)
            }
        }
    }

    // ── Remap ─────────────────────────────────────────────

    static func remap(
        detail: HueSceneDetail,
        targetLights: [HueLight]
    ) -> [RemappedAction] {
        let sortedTargets = targetLights.sorted {
            $0.metadata.name.localizedCompare($1.metadata.name) == .orderedAscending
        }
        let looks = recipes(from: detail.actions ?? [])

        guard !looks.isEmpty else {
            // All-off (or actionless) source → all-off copy.
            return sortedTargets.map {
                RemappedAction(lightID: $0.id, lightName: $0.metadata.name,
                               on: false, brightness: nil, x: nil, y: nil,
                               mirek: nil, downgrade: nil)
            }
        }

        return sortedTargets.enumerated().map { index, light in
            let recipe: Recipe
            if sortedTargets.count >= looks.count {
                recipe = looks[index % looks.count]                       // cycle
            } else {
                recipe = looks[index * looks.count / sortedTargets.count] // sample
            }
            return apply(recipe: recipe, to: light)
        }
    }

    /// Capability downgrade for one target light.
    static func apply(recipe: Recipe, to light: HueLight) -> RemappedAction {
        let name = light.metadata.name
        let supportsColor = light.color != nil
        let ctSchema = light.color_temperature?.mirek_schema
        let supportsCT = light.color_temperature != nil
        let mirekMin = ctSchema?.mirek_minimum ?? 153
        let mirekMax = ctSchema?.mirek_maximum ?? 500

        if let x = recipe.x, let y = recipe.y {
            if supportsColor {
                let gamut = HueColorUtils.Gamut(rawValue: light.color?.gamut_type ?? "C") ?? .c
                let clamped = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: gamut)
                return RemappedAction(lightID: light.id, lightName: name, on: true,
                                      brightness: recipe.brightness,
                                      x: clamped.x, y: clamped.y, mirek: nil, downgrade: nil)
            }
            if supportsCT {
                let approx = HueColorUtils.mirek(fromX: x, y: y, min: mirekMin, max: mirekMax)
                return RemappedAction(lightID: light.id, lightName: name, on: true,
                                      brightness: recipe.brightness,
                                      x: nil, y: nil, mirek: approx,
                                      downgrade: .ctApproximation)
            }
            return RemappedAction(lightID: light.id, lightName: name, on: true,
                                  brightness: recipe.brightness,
                                  x: nil, y: nil, mirek: nil, downgrade: .brightnessOnly)
        }

        if let mirek = recipe.mirek {
            if supportsCT {
                return RemappedAction(lightID: light.id, lightName: name, on: true,
                                      brightness: recipe.brightness,
                                      x: nil, y: nil,
                                      mirek: max(mirekMin, min(mirekMax, mirek)),
                                      downgrade: nil)
            }
            if supportsColor {
                // Render the white as xy so color-only bulbs still match.
                let (h, s, _) = ctAsHSB(mirek: mirek)
                let xy = HueColorUtils.xyFrom(hue: h, saturation: s, brightness: 1)
                return RemappedAction(lightID: light.id, lightName: name, on: true,
                                      brightness: recipe.brightness,
                                      x: xy.x, y: xy.y, mirek: nil, downgrade: nil)
            }
            return RemappedAction(lightID: light.id, lightName: name, on: true,
                                  brightness: recipe.brightness,
                                  x: nil, y: nil, mirek: nil, downgrade: .brightnessOnly)
        }

        return RemappedAction(lightID: light.id, lightName: name, on: true,
                              brightness: recipe.brightness,
                              x: nil, y: nil, mirek: nil,
                              downgrade: recipe.brightness == nil ? .brightnessOnly : nil)
    }

    /// Warm/cool white as HSB, mirroring HueColorUtils.color(fromMirek:)
    /// without going through UIKit (keeps the engine pure for tests).
    private static func ctAsHSB(mirek: Int) -> (h: Double, s: Double, b: Double) {
        let lo = 153.0, hi = 500.0
        let t = (min(max(Double(mirek), lo), hi) - lo) / (hi - lo)  // 0=cool, 1=warm
        // Interpolate the same anchors as color(fromMirek:), then to HSB by hand:
        // warm ≈ amber (h ~0.11, s ~0.65), cool ≈ pale blue (h ~0.61, s ~0.18).
        let h = 0.11 * t + 0.61 * (1 - t)
        let s = 0.65 * t + 0.18 * (1 - t)
        return (h, s, 1.0)
    }

    // ── POST body assembly ────────────────────────────────

    /// Build the CreateSceneRequest for the copy. Dynamic-scene palette,
    /// speed, and auto_dynamic pass through verbatim (palette is scene-level
    /// — the one part of a scene that is inherently room-independent).
    static func request(
        name: String,
        targetGroupID: String,
        targetRtype: String,
        remapped: [RemappedAction],
        detail: HueSceneDetail
    ) -> CreateSceneRequest {
        let actions: [CreateSceneRequest.SceneAction] = remapped.map { r in
            CreateSceneRequest.SceneAction(
                target: .init(rid: r.lightID, rtype: "light"),
                action: .init(
                    on: .init(on: r.on),
                    dimming: (r.on && r.brightness != nil)
                        ? .init(brightness: max(1, min(100, r.brightness!)))
                        : nil,
                    color: (r.x != nil && r.y != nil)
                        ? .init(xy: .init(x: r.x!, y: r.y!))
                        : nil,
                    color_temperature: (r.x == nil && r.mirek != nil)
                        ? .init(mirek: r.mirek!)
                        : nil
                )
            )
        }

        var request = CreateSceneRequest(
            metadata: .init(name: name),
            group: .init(rid: targetGroupID, rtype: targetRtype),
            actions: actions
        )

        // Dynamic palette passthrough (color entries only; CT palette
        // entries are rare and intentionally dropped).
        if let palette = detail.palette,
           let colorEntries = palette.color, !colorEntries.isEmpty {
            let colors: [CreateSceneRequest.Palette.PaletteColor] = colorEntries.compactMap { entry in
                guard let xy = entry.color?.xy else { return nil }
                return .init(
                    color: .init(xy: .init(x: xy.x, y: xy.y)),
                    dimming: .init(brightness: max(1, min(100, entry.dimming?.brightness ?? 80)))
                )
            }
            if !colors.isEmpty {
                let dimmings: [CreateSceneRequest.SceneAction.Action.Dimming] =
                    (palette.dimming ?? []).compactMap { d in
                        d.brightness.map { .init(brightness: max(1, min(100, $0))) }
                    }
                request.palette = .init(
                    color: colors,
                    dimming: dimmings.isEmpty ? [.init(brightness: 80)] : dimmings,
                    color_temperature: []
                )
                request.speed = detail.speed.map { max(0, min(1, $0)) }
                request.auto_dynamic = detail.auto_dynamic
            }
        }

        return request
    }

    /// Rebuild the ORIGINAL scene verbatim from its fetched detail — no
    /// remapping. Used to undo a Move (the original was deleted; its actions
    /// still target its own room's light rids, so a 1:1 re-POST restores it).
    static func recreateRequest(detail: HueSceneDetail) -> CreateSceneRequest {
        let actions: [CreateSceneRequest.SceneAction] = (detail.actions ?? []).map { a in
            CreateSceneRequest.SceneAction(
                target: .init(rid: a.target.rid, rtype: a.target.rtype),
                action: .init(
                    on: a.action.on.map { .init(on: $0.on) },
                    dimming: a.action.dimming?.brightness.map {
                        .init(brightness: max(1, min(100, $0)))
                    },
                    color: a.action.color?.xy.map { .init(xy: .init(x: $0.x, y: $0.y)) },
                    color_temperature: a.action.color_temperature?.mirek.map { .init(mirek: $0) }
                )
            )
        }
        var request = CreateSceneRequest(
            metadata: .init(name: detail.metadata.name),
            group: .init(rid: detail.group.rid, rtype: detail.group.rtype),
            actions: actions
        )
        if let palette = detail.palette,
           let colorEntries = palette.color, !colorEntries.isEmpty {
            let colors: [CreateSceneRequest.Palette.PaletteColor] = colorEntries.compactMap { entry in
                guard let xy = entry.color?.xy else { return nil }
                return .init(
                    color: .init(xy: .init(x: xy.x, y: xy.y)),
                    dimming: .init(brightness: max(1, min(100, entry.dimming?.brightness ?? 80)))
                )
            }
            if !colors.isEmpty {
                request.palette = .init(color: colors,
                                        dimming: [.init(brightness: 80)],
                                        color_temperature: [])
                request.speed = detail.speed.map { max(0, min(1, $0)) }
                request.auto_dynamic = detail.auto_dynamic
            }
        }
        return request
    }
}
