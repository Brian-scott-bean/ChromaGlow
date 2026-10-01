// LuminousStage.swift
// ChromaGlow — Luminous design language: the room, drawn as light.
//
// The Composer's stage painter, fed with what the lamps are doing right now
// instead of a look's frames — so a room on Home, a room's hero and a look in
// the Composer are all the same picture. An orb is a lamp; its colour and
// glow are the lamp's colour and brightness; an off lamp is dark glass.
// These stages are static (they redraw when the lamps change, never on a
// clock): they show the truth, not an animation.

import SwiftUI

// MARK: - Room hero

/// A room's lamps on the Composer's stage, with names. Tap a lamp to open it.
struct LuminousRoomStage: View {
    let lights: [LightDisplayItem]
    var isLive: Bool = false
    var height: CGFloat = 230
    var badge: AnyView? = nil
    var onTapLight: ((LightDisplayItem) -> Void)? = nil

    var body: some View {
        let layout = Composer2SlotLayout.estimated(lights: lights)
        let frames = LuminousLight.frames(for: lights)
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                Canvas(rendersAsynchronously: false) { ctx, size in
                    Composer2HeroPainter.draw(in: &ctx, size: size, layout: layout, frames: frames,
                                              selected: [], motion: Composer2Motion(kind: .static),
                                              geometry: layout.geometry, time: 0, showTrace: false)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard let onTapLight,
                          let index = Self.nearestSlot(to: value.location, size: proxy.size, layout: layout),
                          index < lights.count else { return }
                    HapticManager.shared.light()
                    onTapLight(lights[index])
                })
            }
            if let badge {
                badge.padding(12).allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .luminousStageFrame(isLive: isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(lights))
        .accessibilityHint(onTapLight == nil ? "" : "The lights are listed below")
    }

    /// The slot whose orb is closest to a tap, within a generous radius.
    static func nearestSlot(to point: CGPoint, size: CGSize, layout: Composer2SlotLayout) -> Int? {
        let spots = Composer2HeroPainter.placements(size: size, layout: layout, geometry: layout.geometry)
        var best: (index: Int, distance: CGFloat)?
        for (i, spot) in spots.enumerated() {
            let d = hypot(spot.point.x - point.x, spot.point.y - point.y)
            if d < max(36, spot.radius * 3), d < (best?.distance ?? .infinity) {
                best = (layout.slots[i].index, d)
            }
        }
        return best?.index
    }

    static func summary(_ lights: [LightDisplayItem]) -> String {
        let on = lights.filter(\.isOn).count
        if lights.isEmpty { return "No lights in this room yet" }
        return "Room stage: \(on) of \(lights.count) lights on"
    }
}

// MARK: - Room card stage

/// A small stage for a room card: the lamps in an arc, lit or dark.
struct LuminousMiniRoomStage: View {
    let lights: [LightDisplayItem]
    /// Shown when the lamps aren't known yet (cold cache): the room's own
    /// dominant colour at its brightness, as a single soft glow.
    var fallbackColor: Color? = nil
    var fallbackLevel: Double = 0
    var height: CGFloat = 74

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            if lights.isEmpty {
                LuminousMiniRoomStage.drawFallback(in: &ctx, size: size, color: fallbackColor, level: fallbackLevel)
            } else {
                LuminousMiniRoomStage.draw(in: &ctx, size: size,
                                           lamps: lights.map { (LuminousLight.color(of: $0), LuminousLight.level(of: $0)) })
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Lamps on a gentle arc; each lit lamp throws a wash and a hot core,
    /// each dark lamp is a glass bead. Additive, so neighbours mix like light.
    static func draw(in ctx: inout GraphicsContext, size: CGSize, lamps: [(color: Color, level: Double)],
                     wash washScale: CGFloat = 1) {
        let w = size.width, h = size.height
        let n = lamps.count
        guard n > 0 else { return }
        let shown = min(n, 12)
        let r = min(h * 0.11, w / CGFloat(shown) * 0.2)
        let crowd = CGFloat(min(1, (3.0 / Double(shown)).squareRoot()))
        var light = ctx
        light.blendMode = .plusLighter
        func point(_ i: Int) -> CGPoint {
            let u = shown > 1 ? CGFloat(i) / CGFloat(shown - 1) : 0.5
            return CGPoint(x: w * (0.12 + 0.76 * u), y: h * (0.6 - 0.28 * sin(.pi * u)))
        }
        for i in 0..<shown {
            let lamp = lamps[i]
            let b = CGFloat(max(0, min(1, lamp.level)))
            guard b > 0 else { continue }
            let p = point(i)
            let wash = r * 7 * washScale
            light.fill(Path(ellipseIn: CGRect(x: p.x - wash, y: p.y - wash * 0.8, width: wash * 2, height: wash * 1.6)),
                       with: .radialGradient(Gradient(colors: [lamp.color.opacity(0.22 * b * crowd), .clear]),
                                             center: p, startRadius: 0, endRadius: wash))
            let pool = CGPoint(x: p.x, y: p.y + r * 2.4)
            let poolW = r * 4 * max(0.6, washScale)
            light.fill(Path(ellipseIn: CGRect(x: pool.x - poolW, y: pool.y - r, width: poolW * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [lamp.color.opacity(0.28 * b * crowd), .clear]),
                                             center: pool, startRadius: 0, endRadius: poolW))
        }
        for i in 0..<shown {
            let lamp = lamps[i]
            let b = CGFloat(max(0, min(1, lamp.level)))
            let p = point(i)
            let orb = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: orb), with: .color(Color.white.opacity(0.06)))
            ctx.stroke(Path(ellipseIn: orb), with: .color(Color.white.opacity(b > 0 ? 0.25 : 0.16)), lineWidth: 0.8)
            guard b > 0 else { continue }
            var glow = ctx
            glow.blendMode = .plusLighter
            let halo = r * 3
            glow.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                      with: .radialGradient(Gradient(colors: [lamp.color.opacity(0.55 * b), .clear]),
                                            center: p, startRadius: r * 0.3, endRadius: halo))
            glow.fill(Path(ellipseIn: orb),
                      with: .radialGradient(Gradient(colors: [Color.white.opacity((0.35 + 0.65 * b) * b),
                                                              lamp.color.opacity(0.3 + 0.7 * b)]),
                                            center: CGPoint(x: p.x - r * 0.2, y: p.y - r * 0.25),
                                            startRadius: 0, endRadius: r * 1.1))
        }
        if n > shown {
            let text = Text("+\(n - shown)").font(.system(size: 9, weight: .bold)).foregroundStyle(LuminousPalette.inkSecondary)
            // Below the arc's last lamp — the top corner is where cards put
            // their power button.
            ctx.draw(text, at: CGPoint(x: w - 10, y: h * 0.9))
        }
    }

    static func drawFallback(in ctx: inout GraphicsContext, size: CGSize, color: Color?, level: Double) {
        guard let color, level > 0 else { return }
        var light = ctx
        light.blendMode = .plusLighter
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.55)
        let r = max(size.width, size.height) * 0.6
        light.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.6, width: r * 2, height: r * 1.2)),
                   with: .radialGradient(Gradient(colors: [color.opacity(0.45 * level), .clear]),
                                         center: c, startRadius: 0, endRadius: r))
    }
}

// MARK: - Palette orbs (scenes, moods)

/// A still arc of orbs in a set of colours — a scene's palette or a mood's
/// white. `lit` false draws them as they'd look switched off.
struct LuminousPaletteOrbs: View {
    let colors: [Color]
    var count: Int = 5
    var lit: Bool = true
    var height: CGFloat = 64

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard !colors.isEmpty else { return }
            let lamps = (0..<max(1, count)).map { i in (colors[i % colors.count], lit ? 0.85 : 0.0) }
            LuminousMiniRoomStage.draw(in: &ctx, size: size, lamps: lamps, wash: 0.55)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Room helpers

extension RoomDisplayItem {
    /// The colour the room is showing (its dominant lamp), or warm white.
    var luminousColor: Color {
        if let mirek = dominantMirek, mirek > 0 {
            let p = LuminousLight.xy(mirek: mirek)
            return HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100)
        }
        if let x = dominantColorX, let y = dominantColorY {
            return HueColorUtils.color(fromX: x, y: y, brightness: 100)
        }
        let p = LuminousLight.xy(mirek: 370)
        return HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100)
    }

    /// 0…1 how lit the room is right now.
    var luminousLevel: Double { isOn ? max(0.08, min(1, brightness / 100)) : 0 }
}

extension LightingPreset {
    /// The white each mood sets, as a screen colour.
    var luminousColor: Color {
        let p = LuminousLight.xy(mirek: mirek)
        return HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100)
    }
}
