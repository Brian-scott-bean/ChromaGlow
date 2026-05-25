// ColorPadView.swift
// ChromaGlow — P2 Scene Color Builder
//
// 2D rectangular color pad. Replaces the circular color wheel for scene building.
//   X-axis = saturation (left = white/desaturated, right = fully saturated)
//   Y-axis = brightness  (top = bright, bottom = dark)
//   Hue is set externally via the HueSpectrumBar.
//
// Performance: the gradient is rendered via Canvas (Metal-backed on iOS)
// and only redraws when hue changes. Drag state is pure @State — zero
// re-renders propagated to the parent during drag.

import SwiftUI

// MARK: - ColorPadView

struct ColorPadView: View {

    /// The current hue (0–1) — controlled externally by the hue bar.
    let hue: Double

    /// Current saturation (0–1) — bound to parent.
    @Binding var saturation: Double
    /// Current brightness (0–1) — bound to parent.
    @Binding var brightness: Double

    /// Called once when the user lifts their finger.
    let onCommit: (Double, Double) -> Void   // (saturation, brightness)

    @State private var isDragging = false

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // ── Gradient background ──────────────────────
                Canvas { context, canvasSize in
                    drawGradient(context: context, size: canvasSize, hue: hue)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // ── Border ───────────────────────────────────
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)

                // ── Puck ─────────────────────────────────────
                let puckX = saturation * size.width
                let puckY = (1 - brightness) * size.height

                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
                    .frame(width: isDragging ? 32 : 26,
                           height: isDragging ? 32 : 26)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.35), radius: 3)
                    )
                    .shadow(
                        color: Color(hue: hue, saturation: 1, brightness: 1).opacity(0.5),
                        radius: isDragging ? 12 : 6
                    )
                    .position(x: puckX, y: puckY)
                    .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            HapticManager.shared.medium()
                        }
                        pick(at: value.location, in: size)
                    }
                    .onEnded { value in
                        pick(at: value.location, in: size)
                        isDragging = false
                        HapticManager.shared.heavy()
                        onCommit(saturation, brightness)
                    }
            )
        }
        .aspectRatio(1.4, contentMode: .fit)   // landscape-ish rectangle
    }

    // MARK: - Pick

    private func pick(at point: CGPoint, in size: CGSize) {
        saturation = min(1, max(0, point.x / size.width))
        brightness = min(1, max(0, 1 - point.y / size.height))
    }

    // MARK: - Gradient Renderer

    /// Draws a 2D HSB gradient: saturation on X, brightness on Y, at the given hue.
    private func drawGradient(context: GraphicsContext, size: CGSize, hue: Double) {
        let cols = 32
        let rows = 20
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        for col in 0..<cols {
            for row in 0..<rows {
                let s = Double(col) / Double(cols - 1)
                let b = 1.0 - Double(row) / Double(rows - 1)
                let rect = CGRect(
                    x: CGFloat(col) * cellW,
                    y: CGFloat(row) * cellH,
                    width: cellW + 1,   // +1 eliminates hairline gaps
                    height: cellH + 1
                )
                context.fill(
                    Path(rect),
                    with: .color(Color(hue: hue, saturation: s, brightness: b))
                )
            }
        }
    }
}
