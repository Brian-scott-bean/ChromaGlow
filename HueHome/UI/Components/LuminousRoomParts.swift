// LuminousRoomParts.swift
// ChromaGlow — Luminous design language: pieces the Room and Light screens
// are built from (candidates for LuminousKit).
//
//   • LuminousLampOrb    — one lamp as light: a glass bead with a hot core,
//                           a halo and a pool on the floor, in its real colour.
//   • LuminousTextPill   — a small glass capsule action ("Select", "+ New").
//   • .luminousDock()    — the floating glass dock of the Composer's Go Live
//                           bar, for contextual action bars.
//   • LuminousDockButton — an icon-over-label button for a dock.

import SwiftUI

// MARK: - Lamp orb

/// One lamp drawn as light. `level` is 0…1 (0 = off → dark glass). Static:
/// it redraws when the lamp changes, never on a clock.
struct LuminousLampOrb: View {
    let color: Color
    let level: Double
    var size: CGFloat = 44
    /// Draw the pool the lamp throws below it (big hero orbs).
    var showsFloor: Bool = false

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, canvas in
            LuminousLampOrb.draw(in: &ctx, size: canvas, color: color, level: level, showsFloor: showsFloor)
        }
        .frame(width: size * (showsFloor ? 3.2 : 1.8), height: size * (showsFloor ? 2.6 : 1.8))
        .accessibilityHidden(true)
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, color: Color, level: Double, showsFloor: Bool) {
        let w = size.width, h = size.height
        let b = CGFloat(max(0, min(1, level)))
        let r = min(w / (showsFloor ? 3.2 : 1.8), h / (showsFloor ? 2.6 : 1.8)) / 2
        let p = CGPoint(x: w / 2, y: showsFloor ? h * 0.36 : h / 2)
        var light = ctx
        light.blendMode = .plusLighter
        if b > 0 {
            if showsFloor {
                let floorY = p.y + r * 2.6
                let poolW = r * 3.8, poolH = r * 1.1
                // A round pool squashed onto the floor, so it fades out on
                // every edge instead of being clipped flat top and bottom.
                var pool = light
                pool.translateBy(x: p.x, y: floorY)
                pool.scaleBy(x: 1, y: poolH / poolW)
                pool.fill(Path(ellipseIn: CGRect(x: -poolW, y: -poolW, width: poolW * 2, height: poolW * 2)),
                          with: .radialGradient(Gradient(colors: [color.opacity(0.5 * b), color.opacity(0.14 * b), .clear]),
                                                center: .zero, startRadius: 0, endRadius: poolW))
                var column = Path()
                column.move(to: CGPoint(x: p.x - r * 0.8, y: p.y))
                column.addLine(to: CGPoint(x: p.x + r * 0.8, y: p.y))
                column.addLine(to: CGPoint(x: p.x + r * 2.6, y: floorY))
                column.addLine(to: CGPoint(x: p.x - r * 2.6, y: floorY))
                column.closeSubpath()
                light.fill(column, with: .linearGradient(Gradient(colors: [color.opacity(0.16 * b), .clear]),
                                                         startPoint: p, endPoint: CGPoint(x: p.x, y: floorY)))
            }
            let halo = r * 1.8
            light.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.6 * b), color.opacity(0.12 * b), .clear]),
                                             center: p, startRadius: r * 0.4, endRadius: halo))
        }
        let orb = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: orb), with: .color(Color.white.opacity(0.06)))
        ctx.stroke(Path(ellipseIn: orb), with: .color(Color.white.opacity(b > 0 ? 0.3 : 0.18)), lineWidth: 1)
        guard b > 0 else { return }
        light.fill(Path(ellipseIn: orb),
                   with: .radialGradient(Gradient(colors: [Color.white.opacity((0.35 + 0.65 * b) * b),
                                                           color.opacity(0.35 + 0.65 * b)]),
                                         center: CGPoint(x: p.x - r * 0.22, y: p.y - r * 0.28),
                                         startRadius: 0, endRadius: r * 1.1))
    }
}

// MARK: - Text pill

/// A small glass capsule action — "Select", "Done", "+ New".
struct LuminousTextPill: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.ink
    /// Filled with `tint` (e.g. "Done" while a mode is on).
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.light()
            action()
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                }
                Text(title).font(.footnote.weight(.bold))
            }
            .foregroundStyle(active ? LuminousPalette.void : tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Capsule().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.9) : Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: active ? tint.opacity(0.45) : .clear, radius: 8)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(LuminousPressStyle(scale: 0.94))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Dock

/// The Composer's floating dock surface: deep glass over the room, a bright
/// top edge, a long shadow.
struct LuminousDockSurface: ViewModifier {
    var radius: CGFloat = 28

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(LuminousPalette.void.opacity(0.55)))
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                                                startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 28, y: 10)
            )
            .padding(.horizontal, 12)
    }
}

extension View {
    /// A floating glass dock (contextual action bars).
    func luminousDock(radius: CGFloat = 28) -> some View {
        modifier(LuminousDockSurface(radius: radius))
    }
}

/// Icon over label, for a dock — the Composer's Save/Apply button.
struct LuminousDockButton: View {
    let title: String
    let symbol: String
    var tint: Color = LuminousPalette.ink
    var highlighted: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isEnabled ? tint : LuminousPalette.inkTertiary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(highlighted ? tint.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(highlighted ? tint.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
    }
}
