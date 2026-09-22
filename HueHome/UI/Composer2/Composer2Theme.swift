// Composer2Theme.swift
// ChromaGlow — Composer 2 lab (experimental, isolated under UI/Composer2).
//
// Local design tokens and every user-facing sentence for the Composer 2
// surface. Kept in one file so the visual language stays coherent and the
// copy stays jargon-free (no protocol words reach the person holding the
// phone — the guard tests read this file too).

import SwiftUI

// MARK: - Tokens

enum Composer2Theme {
    static let background = Color(hex: "#070912")
    static let navy = Color(hex: "#0C1024")
    static let ink = Color(hex: "#F2F0EA")
    static let muted = Color(hex: "#8F8C99")
    static let glass = Color.white.opacity(0.06)
    static let glassRaised = Color.white.opacity(0.09)
    static let line = Color.white.opacity(0.10)
    static let lineStrong = Color.white.opacity(0.18)

    static let cyan = Color(hex: "#4FE3FF")
    static let violet = Color(hex: "#9B7BFF")
    static let blue = Color(hex: "#4C8DFF")
    static let magenta = Color(hex: "#FF5CC8")
    static let coral = Color(hex: "#FF8A5C")
    static let live = Color(hex: "#30D158")

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [background, navy, background], startPoint: .top, endPoint: .bottom)
    }

    /// The accent each creative dimension carries through cards and editors.
    static func accent(for dimension: Composer2Dimension) -> Color {
        switch dimension {
        case .palette: return magenta
        case .motion: return cyan
        case .rhythm: return violet
        case .space: return blue
        case .audio: return coral
        case .variation: return Color(hex: "#7CF5D2")
        }
    }

    /// Screen colour for a light frame (Hue chromaticity + brightness).
    static func color(x: Double, y: Double, brightness: Double) -> Color {
        HueColorUtils.color(fromX: x, y: y, brightness: 100)
            .opacity(0.25 + 0.75 * Composer2Math.clamp01(brightness))
    }

    static func solidColor(x: Double, y: Double) -> Color {
        HueColorUtils.color(fromX: x, y: y, brightness: 100)
    }
}

/// The six creative dimensions of the Customize mode.
enum Composer2Dimension: String, CaseIterable, Identifiable {
    case palette, motion, rhythm, space, audio, variation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .palette: return "Palette"
        case .motion: return "Motion"
        case .rhythm: return "Rhythm"
        case .space: return "Space"
        case .audio: return "Audio"
        case .variation: return "Variation"
        }
    }

    var symbol: String {
        switch self {
        case .palette: return "paintpalette.fill"
        case .motion: return "wind"
        case .rhythm: return "waveform.path.ecg"
        case .space: return "square.grid.3x3.topleft.filled"
        case .audio: return "mic.fill"
        case .variation: return "dice.fill"
        }
    }
}

// MARK: - Glass card

struct Composer2GlassCard: ViewModifier {
    var cornerRadius: CGFloat = HueRadius.lg
    var accent: Color? = nil
    var selected: Bool = false
    var raised: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(
                ZStack {
                    shape.fill(raised ? Composer2Theme.glassRaised : Composer2Theme.glass)
                    shape.fill(.ultraThinMaterial.opacity(0.35))
                    if let accent, selected {
                        shape.fill(accent.opacity(0.08))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(
                    selected ? (accent ?? Composer2Theme.cyan).opacity(0.55) : Composer2Theme.line,
                    lineWidth: selected ? 1.2 : 1)
            )
            .shadow(color: selected ? (accent ?? Composer2Theme.cyan).opacity(0.28) : .clear,
                    radius: selected ? 18 : 0)
            .clipShape(shape)
    }
}

extension View {
    func composer2Glass(cornerRadius: CGFloat = HueRadius.lg, accent: Color? = nil,
                        selected: Bool = false, raised: Bool = false) -> some View {
        modifier(Composer2GlassCard(cornerRadius: cornerRadius, accent: accent, selected: selected, raised: raised))
    }
}

// MARK: - Copy

enum Composer2Copy {
    static let title = "Composer"
    static let tagline = "Create light that feels alive."
    static let experimentalBadge = "EXPERIMENTAL"
    static let entryTitle = "Try Composer 2"
    static let entrySubtitle = "An instrument for designing light — layers, motion, rhythm, events."
    static let buildYourOwnTitle = "Build Your Own Light Behavior"
    static let buildYourOwnSubtitle = "Combine primitives. Create something unique."
    static let addBehavior = "Add Behavior"
    static let keepOneBehavior = "Keep at least one behavior."

    static let previewOnly = "Preview only"
    static let liveStreaming = "Live · Streaming"
    static let liveRoomMode = "Live · Room mode"
    static let liveStarting = "Starting…"
    static let liveReconnecting = "Live · reconnecting…"
    static let liveStopping = "Stopping…"
    static let demoHome = "Demo home"
    static let positionsEstimated = "Positions: estimated"
    static let positionsReal = "Positions: from your Entertainment Area"

    static let liveDemoUnavailable = "Live isn't available in Demo Mode. Preview shows this composition on screen."
    static let liveNoBridge = "Live needs a paired bridge — Preview shows this composition on screen."
    static let liveNoRoom = "Choose a room to send this composition to."
    static let liveForeignController = "Another app is controlling these lights. Take over from Studio, then try Live again."
    static let liveEndedElsewhere = "Stopped — another look took over this room."
    static let liveEndedLost = "Stopped — the lights stopped answering. Try Live again."
    static let liveSeveralAreas = "Several Entertainment Areas cover this room. Choose one in Studio to stream; playing in Room mode."
    static let micDenied = "Microphone access is off, so audio reactions are paused."
    static let micListening = "Listening…"
    static let micWaiting = "waiting for sound"

    static let saved = "Saved"
    static let applied = "Applied — keeps playing after you leave, while ChromaGlow stays open."
    static let appliedDetail = "Stops when ChromaGlow quits."
    static let auditionHint = "Live stops when you leave. Apply keeps it playing while the app is open."
    static let takeoverWaiting = "Waiting for your answer…"
    static let takeoverDeclined = "Kept the other app's show. Nothing was changed."
    static let savedLooksTitle = "Your Composer 2 looks"
    static let openInComposer2 = "Open in Composer 2"
    static let saveOverwrite = "Save"
    static let saveAsNew = "Save as new…"
    static let importLegacyTitle = "Import from Composer"
    static let importLegacyHint = "Brings an existing Composer look in as one behavior. The original stays as it is."
    static let importNothing = "No Composer looks to import yet."
    static let collapseAll = "Collapse all"
    static let expandAll = "Expand all"
    static let dragToReorder = "Drag a behavior to reorder"

    static func whiteOnlyNote(_ n: Int) -> String {
        n == 1 ? "1 light shows brightness only" : "\(n) lights show brightness only"
    }

    static func playIn(room: String) -> String {
        "Play in \(room)"
    }

    static func lights(_ n: Int) -> String {
        n == 1 ? "1 light" : "\(n) lights"
    }

    static func playingPill(room: String) -> String {
        "Playing in \(room)"
    }

    // MARK: Summaries (the human-readable value line on each card)

    static func summary(color: Composer2ColorSource) -> String {
        let n = color.sanitizedStops.count
        let style: String
        switch color.interpolation {
        case .linear: style = "smooth"
        case .hueArc: style = "hue blend"
        case .stepped: style = "stepped"
        case .softStepped: style = "soft steps"
        }
        let base = n == 1 ? "1 colour · solid" : "\(n) colours · \(style)"
        return color.drift > 0.05 ? base + " · drifting" : base
    }

    static func summary(motion: Composer2Motion) -> String {
        let kind: String
        switch motion.kind {
        case .static: return "Still"
        case .flow: kind = "Flow"
        case .chase: kind = motion.steps > 0 ? "Chase · \(motion.steps) steps" : "Chase"
        case .wave: kind = "Wave"
        case .bounce: kind = "Bounce"
        case .scatter: kind = "Scatter"
        case .organic: kind = "Organic"
        }
        let speed = speedWord(period: motion.sanitizedPeriod)
        let dir = motion.reverse ? " · reversed" : ""
        return "\(kind) · \(speed)\(dir)"
    }

    static func speedWord(period: Double) -> String {
        switch period {
        case ..<1.5: return "very fast"
        case ..<4: return "fast"
        case ..<12: return "medium"
        case ..<30: return "slow"
        default: return "very slow"
        }
    }

    static func summary(rhythm: Composer2Rhythm) -> String {
        switch rhythm.shape {
        case .steady: return "Steady · \(Int((rhythm.range.hi * 100).rounded()))%"
        case .breathe: return "Breathe · \(tempo(rhythm))"
        case .pulse: return "Pulse · \(tempo(rhythm))"
        case .heartbeat: return "Heartbeat · \(tempo(rhythm))"
        case .flicker: return "Flicker · \(String(format: "%.1f", rhythm.sanitizedFlickerRate))/s"
        case .swell: return "Swell · \(tempo(rhythm))"
        case .burst: return "Burst · \(tempo(rhythm))"
        }
    }

    static func tempo(_ rhythm: Composer2Rhythm) -> String {
        let p = rhythm.sanitizedPeriod
        if p < 2 { return "\(Int(rhythm.bpm.rounded())) BPM" }
        return String(format: "%.0f s", p)
    }

    static func summary(mask: Composer2LayerMask, total: Int, direction: Composer2Motion) -> String {
        let count = mask.selectedCount(total: total)
        let where_: String
        switch mask.kind {
        case .wholeRoom: where_ = "Whole room"
        case .slots, .lightIDs: where_ = "\(count) of \(total) lights"
        case .randomSubset: where_ = "Random \(count) of \(total)"
        case .region: where_ = "Region"
        }
        let axis: String
        switch direction.axisKind {
        case .principal: axis = "along the room"
        case .angle: axis = "\(Int(direction.angleDegrees.rounded()))°"
        case .radial: axis = "from the centre"
        case .angular: axis = "around the centre"
        }
        return "\(where_) · \(axis)"
    }

    static func summary(audio: Composer2AudioModulation) -> String {
        guard audio.isActive else { return "Off" }
        let source = sourceName(audio.source)
        let targets = audio.targets.map(targetName).sorted().joined(separator: ", ")
        return "\(source) → \(targets)"
    }

    static func sourceName(_ source: Composer2AudioModulation.Source) -> String {
        switch source {
        case .off: return "Off"
        case .amplitude: return "Amplitude"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Beat"
        case .onset: return "Hits"
        }
    }

    static func targetName(_ target: Composer2AudioModulation.Target) -> String {
        switch target {
        case .brightness: return "brightness"
        case .palettePosition: return "colour"
        case .motionSpeed: return "speed"
        case .eventProbability: return "events"
        }
    }

    static func summary(variation: Composer2Variation) -> String {
        if let preset = variation.matchingPreset { return presetName(preset) }
        return "Custom · \(Int((variation.amount * 100).rounded()))%"
    }

    static func presetName(_ preset: Composer2Variation.Preset) -> String {
        switch preset {
        case .exact: return "Exact"
        case .subtle: return "Subtle"
        case .organic: return "Organic"
        case .evolving: return "Evolving"
        case .wild: return "Wild"
        }
    }

    static func summary(events: Composer2EventSpec?) -> String {
        guard let e = events?.sanitized else { return "None" }
        let when = e.timing == .fixed
            ? String(format: "every %.1f s", e.interval)
            : String(format: "every %.0f–%.0f s", e.minDelay, e.maxDelay)
        return "\(when) · \(Int((e.probability * 100).rounded()))% chance"
    }

    static func summary(layer: Composer2Layer, total: Int) -> String {
        "\(summary(color: layer.color)) · \(summary(motion: layer.motion))"
    }
}
