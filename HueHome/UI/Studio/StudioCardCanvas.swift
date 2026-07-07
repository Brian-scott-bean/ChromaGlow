// StudioCardCanvas.swift
// CastChroma — Living Cards Animation Engine
//
// Canvas-drawn animated backgrounds for Studio effect cards.
// Each card gets a unique animation derived purely from TimelineView.date.
//
// Performance contract:
//   - Zero @State mutations inside TimelineView
//   - All animation derived from time + card identity
//   - Max 15 particles per card
//   - Each Canvas closure < 2ms execution
//   - isRunning: full framerate | idle: ~15fps

import SwiftUI

struct StudioCardCanvas: View {

    let cardID: String
    let accentColor: Color
    let isRunning: Bool
    let isVisible: Bool  // false = off-screen deck, skip animation entirely

    // Seed derived from cardID — gives each card a unique animation phase
    private var seed: Double {
        Double(cardID.hashValue & 0xFFFF) / 65535.0
    }

    var body: some View {
        if isVisible {
            // Animate: running = full fps, idle = 4fps (subtle, saves GPU)
            TimelineView(.animation(minimumInterval: isRunning ? nil : 0.25)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                canvasContent(time: time)
            }
        } else {
            // Off-screen: single static frame, no timer overhead
            canvasContent(time: 0)
        }
    }

    private func canvasContent(time: Double) -> some View {
        Canvas { context, size in
            let intensity: Double = isRunning ? 1.0 : 0.35

            switch cardID {
            case "candle":      drawCandle(context, size, time, intensity)
            case "fire":        drawFire(context, size, time, intensity)
            case "sparkle":     drawSparkle(context, size, time, intensity)
            case "prism":       drawPrism(context, size, time, intensity)
            case "opal":        drawOpal(context, size, time, intensity)
            case "glisten":     drawGlisten(context, size, time, intensity)
            case "colorloop":   drawColorloop(context, size, time, intensity)
            // R4 Effects port: decorative aliases for the new firmware
            // effects — nearest existing look, purely visual.
            case "cosmos", "enchant": drawOpal(context, size, time, intensity)
            case "sunbeam":     drawCandle(context, size, time, intensity)
            case "underwater":  drawAmbient(context, size, time, intensity)
            case "party":       drawParty(context, size, time, intensity)
            case "strobe":      drawStrobe(context, size, time, intensity)
            case "thunderstorm": drawThunderstorm(context, size, time, intensity)
            case "ambient":     drawAmbient(context, size, time, intensity)
            default:            break
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Effect Animations
    // ──────────────────────────────────────────────

    /// Candle: 4 warm orbs that flicker in opacity and size
    private func drawCandle(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        for i in 0..<4 {
            let fi = Double(i)
            let phase = seed + fi * 1.7
            let flicker = 0.5 + 0.5 * sin(t * (2.5 + fi * 0.7) + phase)
            let radius = (12 + fi * 6) * (0.8 + 0.4 * flicker)
            let x = size.width * (0.3 + fi * 0.15) + sin(t * 0.8 + phase) * 4
            let y = size.height * (0.4 + fi * 0.08) - flicker * 8

            ctx.fill(
                Circle().path(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(flicker * 0.3 * intensity))
            )
        }
    }

    /// Fire: 8 embers that drift upward and fade
    private func drawFire(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        for i in 0..<8 {
            let fi = Double(i)
            let phase = seed + fi * 2.3
            let cycle = (t * (0.3 + fi * 0.08) + phase).truncatingRemainder(dividingBy: 3.0) / 3.0
            let x = size.width * (0.2 + fi * 0.08) + sin(t + phase) * 6
            let y = size.height * (1.0 - cycle * 0.9)
            let fade = 1.0 - cycle
            let r = (3 + fi * 0.8) * fade

            ctx.fill(
                Circle().path(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(fade * 0.35 * intensity))
            )
        }
    }

    /// Sparkle: 10 dots that twinkle on/off at random positions
    private func drawSparkle(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        for i in 0..<10 {
            let fi = Double(i)
            let phase = seed + fi * 3.7
            let blink = max(0, sin(t * (1.5 + fi * 0.6) + phase))
            let sharp = blink * blink * blink // sharper on/off
            let x = size.width * fract(phase * 7.13)
            let y = size.height * fract(phase * 11.37)
            let r = 2.0 + sharp * 3.0

            ctx.fill(
                Circle().path(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(sharp * 0.5 * intensity))
            )
        }
    }

    /// Prism: rotating angular gradient sweep
    private func drawPrism(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let center = CGPoint(x: size.width * 0.6, y: size.height * 0.4)
        let angle = Angle.degrees(t * 30)
        let radius = max(size.width, size.height) * 0.7

        let colors: [Color] = [
            .red.opacity(0.2 * intensity),
            .orange.opacity(0.2 * intensity),
            .yellow.opacity(0.2 * intensity),
            .green.opacity(0.2 * intensity),
            .blue.opacity(0.2 * intensity),
            .purple.opacity(0.2 * intensity),
            .red.opacity(0.2 * intensity),
        ]

        ctx.fill(
            Circle().path(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .conicGradient(
                Gradient(colors: colors),
                center: center,
                angle: angle
            )
        )
    }

    /// Opal: 3 pastel blobs that drift and blend
    private func drawOpal(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let pastels: [Color] = [
            Color(hue: 0.5, saturation: 0.3, brightness: 0.9),
            Color(hue: 0.8, saturation: 0.3, brightness: 0.9),
            accentColor,
        ]
        for i in 0..<3 {
            let fi = Double(i)
            let phase = seed + fi * 2.1
            let x = size.width * (0.3 + 0.4 * sin(t * 0.2 + phase))
            let y = size.height * (0.3 + 0.4 * cos(t * 0.15 + phase * 1.3))
            let r = size.width * 0.35

            ctx.fill(
                Circle().path(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(pastels[i].opacity(0.12 * intensity))
            )
        }
    }

    /// Glisten: concentric rings that pulse outward from center
    private func drawGlisten(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        for i in 0..<4 {
            let fi = Double(i)
            let phase = seed + fi * 0.8
            let expand = ((t * 0.5 + phase).truncatingRemainder(dividingBy: 2.5)) / 2.5
            let r = expand * size.width * 0.6
            let fade = 1.0 - expand

            ctx.stroke(
                Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(fade * 0.25 * intensity)),
                lineWidth: 1.5
            )
        }
    }

    /// Colorloop: rotating hue circle
    private func drawColorloop(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let center = CGPoint(x: size.width * 0.55, y: size.height * 0.45)
        let radius = size.width * 0.4

        let hue = (t * 0.05 + seed).truncatingRemainder(dividingBy: 1.0)
        let color = Color(hue: hue, saturation: 0.7, brightness: 0.9)

        ctx.fill(
            Circle().path(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.25 * intensity), .clear]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Mode Animations
    // ──────────────────────────────────────────────



    /// Party: 12 confetti pieces drifting down
    private func drawParty(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let hues: [Double] = [0.0, 0.08, 0.16, 0.33, 0.55, 0.75]
        for i in 0..<12 {
            let fi = Double(i)
            let phase = seed + fi * 4.1
            let fall = ((t * (0.2 + fi * 0.03) + phase).truncatingRemainder(dividingBy: 4.0)) / 4.0
            let x = size.width * fract(phase * 3.7) + sin(t * 0.5 + phase) * 8
            let y = size.height * fall
            let hue = hues[i % hues.count]
            let color = Color(hue: hue, saturation: 0.8, brightness: 0.9)

            ctx.fill(
                RoundedRectangle(cornerRadius: 1).path(in: CGRect(x: x - 2, y: y - 3, width: 4, height: 6)),
                with: .color(color.opacity(0.35 * intensity))
            )
        }
    }

    /// Strobe: full-card pulse flash
    private func drawStrobe(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let rate = isRunning ? 6.0 : 1.5
        let pulse = max(0, sin(t * rate + seed))
        let sharp = pulse * pulse * pulse
        let color = Color.white

        ctx.fill(
            Rectangle().path(in: CGRect(origin: .zero, size: size)),
            with: .color(color.opacity(sharp * 0.15 * intensity))
        )
    }

    /// Thunderstorm: random lightning flashes
    private func drawThunderstorm(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        // Simulated random flash using sin products
        let flash1 = max(0, sin(t * 1.3 + seed) * sin(t * 3.7 + seed * 2))
        let flash2 = max(0, sin(t * 0.7 + seed + 5) * sin(t * 2.1 + seed * 3))
        let sharp1 = flash1 > 0.7 ? (flash1 - 0.7) / 0.3 : 0
        let sharp2 = flash2 > 0.8 ? (flash2 - 0.8) / 0.2 : 0

        // Flash overlay
        let flashIntensity = max(sharp1, sharp2)
        ctx.fill(
            Rectangle().path(in: CGRect(origin: .zero, size: size)),
            with: .color(Color.white.opacity(flashIntensity * 0.2 * intensity))
        )

        // Ambient dim glow
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.6)
        ctx.fill(
            Circle().path(in: CGRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120)),
            with: .color(color.opacity(0.08 * intensity))
        )
    }

    /// Ambient: single orb that breathes in size and opacity
    private func drawAmbient(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ intensity: Double) {
        let color = accentColor
        let breathe = 0.5 + 0.5 * sin(t * 0.4 + seed)
        let r = size.width * (0.2 + 0.15 * breathe)
        let center = CGPoint(
            x: size.width * 0.5 + sin(t * 0.15 + seed) * 10,
            y: size.height * 0.45 + cos(t * 0.12 + seed) * 8
        )

        ctx.fill(
            Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.2 * intensity * breathe), .clear]),
                center: center,
                startRadius: 0,
                endRadius: r
            )
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Utility
    // ──────────────────────────────────────────────

    /// Fractional part (like GLSL fract)
    private func fract(_ x: Double) -> Double {
        x - floor(x)
    }
}
