// HueSpectrumBar.swift
// CastChroma — P2 Scene Color Builder
//
// Full-width horizontal hue slider. Renders the 0–360° spectrum as a
// rainbow gradient capsule with a draggable thumb.
//
// When a harmony rule is active, small marker dots appear at the derived
// hue positions so the user can see the full palette at a glance.

import SwiftUI

// MARK: - HueSpectrumBar

struct HueSpectrumBar: View {

    /// Current hue (0–1) — bound to parent.
    @Binding var hue: Double

    /// The harmony rule in effect — used to show anchor markers.
    var harmonyRule: HarmonyRule = .none

    /// Called once when the user lifts their finger.
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    @State private var lastNotch: Int = 0

    // Full hue spectrum colors
    private let spectrumColors: [Color] = stride(from: 0.0, through: 1.0, by: 1.0/12.0).map {
        Color(hue: $0, saturation: 1.0, brightness: 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                // ── Spectrum gradient ─────────────────────
                LinearGradient(
                    colors: spectrumColors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(Capsule())
                .frame(height: 12)

                // ── Harmony anchor markers ────────────────
                if harmonyRule != .none {
                    ForEach(Array(harmonyMarkerHues.enumerated()), id: \.offset) { _, markerHue in
                        let markerX = markerHue * width
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .position(x: markerX, y: 16)
                    }
                }

                // ── Thumb ────────────────────────────────
                let thumbX = hue * width
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .frame(width: isDragging ? 30 : 24,
                           height: isDragging ? 30 : 24)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.3), radius: 3)
                    )
                    .shadow(
                        color: Color(hue: hue, saturation: 1, brightness: 1).opacity(0.6),
                        radius: isDragging ? 10 : 5
                    )
                    .position(x: thumbX, y: 16)
                    .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isDragging)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            HapticManager.shared.medium()
                        }
                        let raw = value.location.x / width
                        hue = min(1, max(0, raw))

                        // Haptic notch every ~30° (1/12)
                        let notch = Int(hue * 12)
                        if notch != lastNotch {
                            HapticManager.shared.soft()
                            lastNotch = notch
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        HapticManager.shared.heavy()
                        onCommit(hue)
                    }
            )
        }
        .frame(height: 32)
    }

    // MARK: - Harmony Markers

    /// The derived hue positions for the current harmony rule (excludes root).
    private var harmonyMarkerHues: [Double] {
        let anchors = HarmonyEngine.anchorHues(for: harmonyRule, rootHue: hue)
        // Skip the first one (root hue — that's the thumb itself)
        return Array(anchors.dropFirst())
    }
}
