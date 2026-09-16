// Composer2HeroCard.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// "I can see what this composition is doing to my space." One glow emitter
// per light, drawn from the same frames the runtime sends to the bulbs. Real
// positions when the Entertainment Area gave them, a labelled estimate when
// it did not — never a fabricated layout presented as fact.

import SwiftUI
import QuartzCore

struct Composer2HeroCard: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    let feed: Composer2PreviewFeed
    let previewOn: Bool
    let onTapLights: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive

    private var isTicking: Bool {
        (previewOn || center.isLive) && isTabActive && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.composition.name)
                        .font(HueFont.stageName)
                        .foregroundStyle(Composer2Theme.ink)
                        .lineLimit(1)
                    Text("\(document.roomContext.roomName) · \(Composer2Copy.lights(document.roomContext.lightCount))")
                        .font(HueFont.stageStatus)
                        .foregroundStyle(Composer2Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                StageBadge(text: center.isLive ? "LIVE" : (previewOn ? "PREVIEW" : "PAUSED"),
                           style: center.isLive ? .live : .muted)
            }

            Composer2HeroCanvas(layout: document.roomContext.layout,
                                feed: feed,
                                selected: document.selectedSlots,
                                isTicking: isTicking,
                                reduceMotion: reduceMotion,
                                motion: document.selectedLayer.motion,
                                geometry: document.roomContext.layout.geometry)
                .frame(height: 200)
                .contentShape(Rectangle())
                .onTapGesture {
                    HapticManager.shared.light()
                    onTapLights()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint("Double tap to choose lights")

            HStack(spacing: 8) {
                badge(document.roomContext.layout.positionsAreEstimated ? Composer2Copy.positionsEstimated : Composer2Copy.positionsReal,
                      symbol: document.roomContext.layout.positionsAreEstimated ? "questionmark.circle" : "scope")
                if let mode = center.session?.playMode {
                    badge(mode == .streaming ? TransportVocabulary.streamingSubtitle : TransportVocabulary.roomModeSubtitle,
                          symbol: mode == .streaming ? "dot.radiowaves.left.and.right" : "house")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(HueSpacing.lg)
        .composer2Glass(accent: Composer2Theme.cyan, selected: center.isLive)
    }

    private func badge(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(HueFont.stageStatus).lineLimit(1)
        }
        .foregroundStyle(Composer2Theme.muted)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Capsule().fill(Composer2Theme.glass))
    }

    private var accessibilitySummary: String {
        let state = center.isLive ? "live" : (previewOn ? "previewing" : "paused")
        let positions = document.roomContext.layout.positionsAreEstimated ? "positions estimated" : "positions from your Entertainment Area"
        return "Room preview, \(Composer2Copy.lights(document.roomContext.lightCount)), \(document.roomContext.roomName), \(state), \(positions)"
    }
}

// MARK: - Canvas

struct Composer2HeroCanvas: View {
    let layout: Composer2SlotLayout
    let feed: Composer2PreviewFeed
    let selected: Set<Int>
    let isTicking: Bool
    let reduceMotion: Bool
    let motion: Composer2Motion
    let geometry: Composer2SlotGeometry

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 20.0, paused: !isTicking)) { _ in
            Canvas(rendersAsynchronously: false) { context, size in
                feed.timeScale = reduceMotion ? 0.5 : 1
                let now = CACurrentMediaTime()
                let frames = feed.displayFrames(hostNow: now)
                Composer2HeroPainter.draw(in: &context, size: size, layout: layout, frames: frames,
                                          selected: selected, motion: motion, geometry: geometry,
                                          time: now, showTrace: !reduceMotion && motion.kind != .static)
            }
        }
    }
}

// MARK: - Painter (pure drawing, no state)

enum Composer2HeroPainter {
    static func draw(in ctx: inout GraphicsContext, size: CGSize, layout: Composer2SlotLayout,
                     frames: [Composer2Frame], selected: Set<Int>, motion: Composer2Motion,
                     geometry: Composer2SlotGeometry, time: Double, showTrace: Bool) {
        let w = size.width, h = size.height
        // Floor: a soft navy ellipse gives the room depth.
        let floor = CGRect(x: w * 0.04, y: h * 0.42, width: w * 0.92, height: h * 0.62)
        ctx.fill(Path(ellipseIn: floor),
                 with: .radialGradient(Gradient(colors: [Composer2Theme.navy.opacity(0.9), Composer2Theme.background.opacity(0)]),
                                       center: CGPoint(x: floor.midX, y: floor.midY),
                                       startRadius: 0, endRadius: floor.width * 0.55))
        ctx.stroke(Path(ellipseIn: floor.insetBy(dx: 2, dy: 2)), with: .color(Composer2Theme.line), lineWidth: 1)

        let count = layout.count
        guard count > 0 else {
            let text = Text("No lights in this room yet").font(.system(size: 12, weight: .medium)).foregroundStyle(Composer2Theme.muted)
            ctx.draw(text, at: CGPoint(x: w / 2, y: h / 2))
            return
        }

        if showTrace {
            drawTrace(in: &ctx, size: size, motion: motion, geometry: geometry, time: time)
        }

        let insetX = w * 0.11, topY = h * 0.14, bottomY = h * 0.84
        let hasSelection = !selected.isEmpty
        let baseRadius = max(7.0, min(13.0, 34.0 / Double(count).squareRoot()))

        for slot in layout.slots {
            let nx = slot.x ?? geometry.linearIndex[min(slot.index, max(0, geometry.linearIndex.count - 1))]
            let nz = slot.z ?? 0.5
            let px = insetX + nx * (w - 2 * insetX)
            let py = topY + nz * (bottomY - topY)
            let r = baseRadius * (0.8 + 0.4 * nz)   // farther (top) = smaller
            let frame = slot.index < frames.count ? frames[slot.index] : nil
            let brightness = frame?.brightness ?? 0
            let color = frame.map { Composer2Theme.solidColor(x: $0.x, y: $0.y) } ?? Composer2Theme.muted
            let dim = hasSelection && !selected.contains(slot.index) ? 0.55 : 1.0
            let center = CGPoint(x: px, y: py)

            let bloomR = r * 3.2
            ctx.fill(Path(ellipseIn: CGRect(x: px - bloomR, y: py - bloomR, width: bloomR * 2, height: bloomR * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.22 * brightness * dim), color.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: bloomR))
            let midR = r * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: px - midR, y: py - midR, width: midR * 2, height: midR * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.5 * brightness * dim), color.opacity(0)]),
                                           center: center, startRadius: r * 0.4, endRadius: midR))
            let coreAlpha = (0.28 + 0.72 * brightness) * dim
            ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(coreAlpha)))
            ctx.stroke(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                       with: .color(Color.white.opacity(0.18 * dim)), lineWidth: 1)
            if brightness > 0.6 {
                let sr = r * 0.28
                ctx.fill(Path(ellipseIn: CGRect(x: px - r * 0.35 - sr, y: py - r * 0.35 - sr, width: sr * 2, height: sr * 2)),
                         with: .color(Color.white.opacity((brightness - 0.6) * 1.8 * dim)))
            }
            if selected.contains(slot.index) {
                let ring = r * 1.45
                ctx.stroke(Path(ellipseIn: CGRect(x: px - ring, y: py - ring, width: ring * 2, height: ring * 2)),
                           with: .color(Composer2Theme.cyan), lineWidth: 2)
                let halo = r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: px - halo, y: py - halo, width: halo * 2, height: halo * 2)),
                         with: .radialGradient(Gradient(colors: [Composer2Theme.cyan.opacity(0.28), .clear]),
                                               center: center, startRadius: ring, endRadius: halo))
            }
            if count <= 10 {
                let label = Text(slot.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Composer2Theme.muted.opacity(dim))
                ctx.draw(label, at: CGPoint(x: px, y: py + r + 9))
            }
        }
    }

    /// A dashed line through the room along the motion axis, its dash phase
    /// advancing with time — movement is visible even in a two-light room.
    private static func drawTrace(in ctx: inout GraphicsContext, size: CGSize, motion: Composer2Motion,
                                  geometry: Composer2SlotGeometry, time: Double) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = h * 0.5
        var path = Path()
        switch motion.axisKind {
        case .radial:
            for i in 1...3 {
                let rr = Double(i) * min(w, h) * 0.16
                path.addEllipse(in: CGRect(x: cx - rr, y: cy - rr * 0.6, width: rr * 2, height: rr * 1.2))
            }
        case .angular:
            let rr = min(w, h) * 0.34
            path.addEllipse(in: CGRect(x: cx - rr, y: cy - rr * 0.6, width: rr * 2, height: rr * 1.2))
        case .principal, .angle:
            let degrees = motion.axisKind == .angle ? motion.angleDegrees : geometry.principalAngleDegrees
            let rad = degrees * .pi / 180
            let dx = cos(rad) * w * 0.42, dy = sin(rad) * h * 0.32
            path.move(to: CGPoint(x: cx - dx, y: cy - dy))
            path.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
        }
        let direction: Double = motion.reverse ? 1 : -1
        let speed = 40.0 / max(0.5, motion.sanitizedPeriod)
        let phase = direction * time * speed
        ctx.stroke(path, with: .color(Composer2Theme.cyan.opacity(0.22)),
                   style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 9], dashPhase: phase))
    }
}
