// Composer2HeroCard.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2 luminous stage.
//
// "I can see what this composition is doing to my space." Every light is a
// glowing orb that pools light on the floor and washes the room around it —
// drawn additively, so two lights overlapping mix the way light does. The
// frames are the same ones the runtime sends to the bulbs. Real positions
// when the Entertainment Area gave them, a labelled estimate when it did
// not — never a fabricated layout presented as fact.

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

    private var isLiveHere: Bool { center.isPlaying(document: document) }

    private var isTicking: Bool {
        (previewOn || isLiveHere) && isTabActive && !KeyboardState.shared.isKeyboardUp
    }

    var body: some View {
        ZStack(alignment: .top) {
            Composer2HeroCanvas(layout: document.roomContext.layout,
                                feed: feed,
                                selected: document.selectedSlots,
                                isTicking: isTicking,
                                reduceMotion: reduceMotion,
                                motion: document.selectedLayer.motion,
                                geometry: document.roomContext.layout.geometry)
                .contentShape(Rectangle())
                .onTapGesture {
                    HapticManager.shared.light()
                    onTapLights()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint("Double tap to choose which lights each behavior uses")
                .accessibilityAddTraits(.isButton)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Composer2LiveBadge(state: badgeState)
                    Spacer(minLength: 0)
                    Label(Composer2Copy.lights(document.roomContext.lightCount), systemImage: "lightbulb.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Composer2Theme.ink.opacity(0.75))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 26)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    badge(document.roomContext.layout.positionsAreEstimated ? Composer2Copy.positionsEstimated : Composer2Copy.positionsReal,
                          symbol: document.roomContext.layout.positionsAreEstimated ? "questionmark.circle" : "scope")
                    if isLiveHere, let mode = center.session?.playMode {
                        badge(mode == .streaming ? TransportVocabulary.streamingSubtitle : TransportVocabulary.roomModeSubtitle,
                              symbol: mode == .streaming ? "dot.radiowaves.left.and.right" : "house")
                    }
                    if document.roomContext.layout.whiteOnlyCount > 0 {
                        badge(Composer2Copy.whiteOnlyNote(document.roomContext.layout.whiteOnlyCount), symbol: "lightbulb")
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .frame(height: 260)
        .background(Composer2Theme.void)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(isLiveHere ? 0.35 : 0.16), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    private var badgeState: Composer2LiveBadge.Mode {
        if isLiveHere { return .live }
        return previewOn ? .preview : .paused
    }

    private func badge(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(HueFont.stageStatus).lineLimit(1)
        }
        .foregroundStyle(Composer2Theme.ink.opacity(0.7))
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private var accessibilitySummary: String {
        let state = isLiveHere ? "live" : (previewOn ? "previewing" : "paused")
        let positions = document.roomContext.layout.positionsAreEstimated ? "positions estimated" : "positions from your Entertainment Area"
        return "Room preview, \(Composer2Copy.lights(document.roomContext.lightCount)), \(document.roomContext.roomName), \(state), \(positions)"
    }
}

// MARK: - Live badge

struct Composer2LiveBadge: View {
    enum Mode { case live, preview, paused }
    let state: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .shadow(color: dot.opacity(0.9), radius: state == .live ? 5 : 0)
                .scaleEffect(state == .live && pulse && !reduceMotion ? 1.35 : 1)
            Text(text)
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(state == .live ? Composer2Theme.live : Composer2Theme.ink.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(state == .live ? Composer2Theme.live.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(text.capitalized)
    }

    private var dot: Color {
        switch state {
        case .live: return Composer2Theme.live
        case .preview: return Composer2Theme.cyan
        case .paused: return Composer2Theme.muted
        }
    }

    private var text: String {
        switch state {
        case .live: return "LIVE"
        case .preview: return "PREVIEW"
        case .paused: return "PAUSED"
        }
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
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0, paused: !isTicking)) { _ in
            Canvas(rendersAsynchronously: false) { context, size in
                feed.timeScale = reduceMotion ? 0.5 : 1
                let now = CACurrentMediaTime()
                let frames = feed.displayFrames(hostNow: now,
                                                features: AudioAnalysisEngine.latestFeatures(),
                                                beat: BeatClock.snapshot())
                Composer2HeroPainter.draw(in: &context, size: size, layout: layout, frames: frames,
                                          selected: selected, motion: motion, geometry: geometry,
                                          time: now, showTrace: !reduceMotion && motion.kind != .static)
            }
        }
    }
}

// MARK: - Painter (pure drawing, no state)

enum Composer2HeroPainter {
    /// Where a slot sits on screen and how big it reads (nearer = larger).
    struct Placement {
        let point: CGPoint
        let radius: CGFloat
        let depth: CGFloat
    }

    static func placements(size: CGSize, layout: Composer2SlotLayout, geometry: Composer2SlotGeometry) -> [Placement] {
        let w = size.width, h = size.height
        let count = layout.count
        let base = CGFloat(max(7.0, min(15.0, 38.0 / Double(max(1, count)).squareRoot())))
        return layout.slots.map { slot in
            let nx = slot.x ?? geometry.linearIndex[min(slot.index, max(0, geometry.linearIndex.count - 1))]
            let nz = slot.z ?? 0.5
            // A gentle perspective: the back of the room is narrower and higher.
            let depth = CGFloat(nz)
            let inset = w * (0.2 - 0.08 * depth)
            let x = inset + CGFloat(nx) * (w - 2 * inset)
            let y = h * (0.3 + 0.46 * depth)
            return Placement(point: CGPoint(x: x, y: y), radius: base * (0.75 + 0.5 * depth), depth: depth)
        }
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, layout: Composer2SlotLayout,
                     frames: [Composer2Frame], selected: Set<Int>, motion: Composer2Motion,
                     geometry: Composer2SlotGeometry, time: Double, showTrace: Bool) {
        let w = size.width, h = size.height
        drawRoom(in: &ctx, size: size)

        let count = layout.count
        guard count > 0 else {
            let text = Text("No lights in this room yet").font(.system(size: 13, weight: .medium)).foregroundStyle(Composer2Theme.muted)
            ctx.draw(text, at: CGPoint(x: w / 2, y: h / 2))
            return
        }
        if showTrace {
            drawTrace(in: &ctx, size: size, motion: motion, geometry: geometry, time: time)
        }

        let spots = placements(size: size, layout: layout, geometry: geometry)
        let hasSelection = !selected.isEmpty
        // Back to front, so nearer lights sit on top.
        let order = spots.indices.sorted { spots[$0].depth < spots[$1].depth }

        // Pass 1 — light in the room: washes and floor pools, additive.
        var light = ctx
        light.blendMode = .plusLighter
        for i in order {
            let slot = layout.slots[i]
            guard let frame = slot.index < frames.count ? frames[slot.index] : nil else { continue }
            let b = CGFloat(Composer2Math.clamp01(frame.brightness))
            guard b > 0.01 else { continue }
            let color = Composer2Theme.solidColor(x: frame.x, y: frame.y)
            let p = spots[i].point, r = spots[i].radius
            // The room around the light.
            let washR = r * 13
            light.fill(Path(ellipseIn: CGRect(x: p.x - washR, y: p.y - washR * 0.8, width: washR * 2, height: washR * 1.6)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.16 * b), color.opacity(0)]),
                                             center: p, startRadius: 0, endRadius: washR))
            // The pool it throws on the floor.
            let floorY = p.y + r * 2.2
            let poolW = r * 7, poolH = r * 2.2
            light.fill(Path(ellipseIn: CGRect(x: p.x - poolW, y: floorY - poolH, width: poolW * 2, height: poolH * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.42 * b), color.opacity(0)]),
                                             center: CGPoint(x: p.x, y: floorY), startRadius: 0, endRadius: poolW))
            // A soft column between the lamp and its pool.
            var column = Path()
            column.move(to: CGPoint(x: p.x - r * 0.9, y: p.y))
            column.addLine(to: CGPoint(x: p.x + r * 0.9, y: p.y))
            column.addLine(to: CGPoint(x: p.x + r * 2.4, y: floorY))
            column.addLine(to: CGPoint(x: p.x - r * 2.4, y: floorY))
            column.closeSubpath()
            light.fill(column, with: .linearGradient(Gradient(colors: [color.opacity(0.18 * b), color.opacity(0)]),
                                                     startPoint: p, endPoint: CGPoint(x: p.x, y: floorY)))
        }

        // Pass 2 — the lamps themselves.
        for i in order {
            let slot = layout.slots[i]
            let p = spots[i].point, r = spots[i].radius
            let frame = slot.index < frames.count ? frames[slot.index] : nil
            let b = CGFloat(Composer2Math.clamp01(frame?.brightness ?? 0))
            let color = frame.map { Composer2Theme.solidColor(x: $0.x, y: $0.y) } ?? Composer2Theme.muted
            let dim: CGFloat = hasSelection && !selected.contains(slot.index) ? 0.5 : 1
            let orb = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            // Glass body, always visible so the room reads even when dark.
            ctx.fill(Path(ellipseIn: orb), with: .color(Color.white.opacity(0.05 * dim)))
            ctx.stroke(Path(ellipseIn: orb), with: .color(Color.white.opacity(0.16 * dim)), lineWidth: 1)

            var glow = ctx
            glow.blendMode = .plusLighter
            let haloR = r * 3.4
            glow.fill(Path(ellipseIn: CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)),
                      with: .radialGradient(Gradient(colors: [color.opacity(0.55 * b * dim), color.opacity(0)]),
                                            center: p, startRadius: r * 0.3, endRadius: haloR))
            // A hot core: white at the centre, the colour at the rim.
            glow.fill(Path(ellipseIn: orb),
                      with: .radialGradient(Gradient(colors: [Color.white.opacity((0.35 + 0.65 * b) * b * dim),
                                                              color.opacity((0.3 + 0.7 * b) * dim)]),
                                            center: CGPoint(x: p.x - r * 0.2, y: p.y - r * 0.25),
                                            startRadius: 0, endRadius: r * 1.1))

            if !slot.isColour {
                // A light that follows brightness only: a quiet dashed ring says so.
                let wr = r * 1.35
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - wr, y: p.y - wr, width: wr * 2, height: wr * 2)),
                           with: .color(Color.white.opacity(0.45 * dim)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if selected.contains(slot.index) {
                let ring = r * 1.55
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(Composer2Theme.cyan), lineWidth: 2)
            }
            if count <= 8 {
                let label = Text(slot.name).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Composer2Theme.ink.opacity(0.45 * dim))
                ctx.draw(label, at: CGPoint(x: p.x, y: p.y + r * 2.9 + 6))
            }
        }
    }

    /// The room: a dark floor receding to a horizon, with the faintest grid.
    private static func drawRoom(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let horizon = h * 0.22
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Composer2Theme.void, Composer2Theme.navy.opacity(0.9), Composer2Theme.void]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        var grid = Path()
        for k in 0...8 {
            let t = CGFloat(k) / 8
            let bottomX = w * t
            let topX = w * (0.3 + 0.4 * t)
            grid.move(to: CGPoint(x: topX, y: horizon))
            grid.addLine(to: CGPoint(x: bottomX, y: h))
        }
        for k in 1...5 {
            let t = CGFloat(k) / 5
            let y = horizon + (h - horizon) * t * t
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.stroke(grid, with: .linearGradient(Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.07)]),
                                               startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)),
                   lineWidth: 0.6)
    }

    /// A glowing dashed line along the motion axis, its dash phase advancing
    /// with time — movement is visible even in a two-light room.
    private static func drawTrace(in ctx: inout GraphicsContext, size: CGSize, motion: Composer2Motion,
                                  geometry: Composer2SlotGeometry, time: Double) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = h * 0.55
        var path = Path()
        switch motion.axisKind {
        case .radial:
            for i in 1...3 {
                let rr = Double(i) * min(w, h) * 0.15
                path.addEllipse(in: CGRect(x: cx - rr, y: cy - rr * 0.45, width: rr * 2, height: rr * 0.9))
            }
        case .angular:
            let rr = min(w, h) * 0.36
            path.addEllipse(in: CGRect(x: cx - rr, y: cy - rr * 0.45, width: rr * 2, height: rr * 0.9))
        case .principal, .angle:
            let degrees = motion.axisKind == .angle ? motion.angleDegrees : geometry.principalAngleDegrees
            let rad = degrees * .pi / 180
            let dx = cos(rad) * w * 0.4, dy = sin(rad) * h * 0.22
            path.move(to: CGPoint(x: cx - dx, y: cy - dy))
            path.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
        }
        let direction: Double = motion.reverse ? 1 : -1
        let speed = 40.0 / max(0.5, motion.sanitizedPeriod)
        let phase = direction * time * speed
        ctx.stroke(path, with: .color(Composer2Theme.cyan.opacity(0.16)),
                   style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 10], dashPhase: phase))
    }
}
