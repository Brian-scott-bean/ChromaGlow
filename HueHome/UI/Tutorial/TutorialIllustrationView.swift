// TutorialIllustrationView.swift
// ChromaGlow — the Welcome Tour's live illustrations
//
// One animated composition per tour page, built entirely from SF Symbols and
// StageKit primitives — no image assets. Every frame is a pure function of
// wall time (the PatternStripView discipline): one TimelineView, zero
// accumulated @State, so pausing, replaying, and Reduce Motion are all just
// choices of `t`. With Reduce Motion the timeline freezes at a curated
// instant so each composition reads as an intentional still.
//
// Photosensitivity: nothing here cycles faster than ~1.3Hz — the tour obeys
// the same 3-flashes-per-second discipline as the light engines it previews.

import SwiftUI

/// Pure motion helpers for the tour compositions. Kept math-only (no SwiftUI
/// types) so TutorialCatalogTests can pin their bounds and periodicity.
enum TourMotionMath {
    /// 0→1 sawtooth with the given period.
    static func wrap(_ time: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let p = (time / period).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }

    /// Smooth 0→1→0 breathing curve with the given period (starts at 0).
    static func pulse(_ time: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        return 0.5 - 0.5 * cos(2 * .pi * time / period)
    }

    /// Which of `count` steps is highlighted at `time`; advances every `period`.
    static func hop(_ time: Double, count: Int, period: Double) -> Int {
        guard count > 0, period > 0 else { return 0 }
        let step = Int(floor(time / period)) % count
        return step < 0 ? step + count : step
    }

    /// Hermite ease-in-out, clamped to 0…1.
    static func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// Eased 0→1 progress of the slice [from, to] inside a 0→1 phase.
    static func segment(_ phase: Double, from: Double, to: Double) -> Double {
        guard to > from else { return phase >= to ? 1 : 0 }
        return ease((phase - from) / (to - from))
    }
}

/// The tour page artwork. Decorative only — hidden from accessibility; the
/// page's text carries all meaning.
struct TutorialIllustrationView: View {
    let kind: TutorialPage.Illustration
    let accent: Color
    /// True only for the visible page — neighbors in the pager stay frozen.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The instant shown when Reduce Motion is on — picked so every
    /// composition looks deliberate as a still.
    private static let frozenTime: Double = 1.9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !isActive || reduceMotion)) { timeline in
            let t = reduceMotion ? Self.frozenTime : timeline.date.timeIntervalSinceReferenceDate
            composition(time: t)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func composition(time t: Double) -> some View {
        switch kind {
        case .welcome:     WelcomeArt(accent: accent, t: t)
        case .rooms:       RoomsArt(accent: accent, t: t)
        case .moods:       MoodsArt(accent: accent, t: t)
        case .roomDetail:  RoomDetailArt(accent: accent, t: t)
        case .scenes:      ScenesArt(accent: accent, t: t, live: isActive && !reduceMotion)
        case .studio:      StudioArt(accent: accent, t: t, live: isActive && !reduceMotion)
        case .composer:    ComposerArt(accent: accent, t: t, live: isActive && !reduceMotion)
        case .perform:     PerformArt(accent: accent, t: t)
        case .automations: AutomationsArt(accent: accent, t: t)
        case .family:      FamilyArt(accent: accent, t: t)
        case .everywhere:  EverywhereArt(accent: accent, t: t)
        case .wrap:        WrapArt(accent: accent, t: t)
        }
    }
}

// MARK: - Shared mockup primitives

private let tourSurface = Color.white.opacity(0.06)

private struct MockCard<Content: View>: View {
    var glow: Double = 0
    var accent: Color = HuePalette.amber
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(tourSurface)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.22 * glow)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(glow > 0.05 ? accent.opacity(0.25 + 0.5 * glow) : StagePalette.line,
                                  lineWidth: 1)
            )
    }
}

private struct MockSlider: View {
    let fraction: Double
    var accent: Color = HuePalette.amber

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(StagePalette.raised).frame(height: 4)
                Capsule().fill(accent.opacity(0.8))
                    .frame(width: max(8, w * fraction), height: 4)
                Circle().fill(StagePalette.ink)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, w * fraction - 6))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
    }
}

private struct MonoTag: View {
    let text: String
    var color: Color = StagePalette.muted

    var body: some View {
        Text(text)
            .font(HueFont.stageTag)
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - 1. Welcome — brand mark with an orbiting hue ring

private struct WelcomeArt: View {
    let accent: Color
    let t: Double

    var body: some View {
        let breathe = TourMotionMath.pulse(t, period: 3.0)
        let orbit = TourMotionMath.wrap(t, period: 12.0)
        ZStack {
            Circle()
                .fill(accent.opacity(0.10 + 0.12 * breathe))
                .frame(width: 190, height: 190)
                .blur(radius: 24)
            ForEach(0..<8, id: \.self) { i in
                let angle = 2 * .pi * (Double(i) / 8 + orbit)
                Circle()
                    .fill(Color(hue: Double(i) / 8, saturation: 0.75, brightness: 0.95))
                    .frame(width: 10, height: 10)
                    .offset(x: 82 * cos(angle), y: 82 * sin(angle))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [Color(hex: "#1F1A38"), Color(hex: "#141224")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 92, height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StagePalette.line, lineWidth: 1))
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.35 + 0.3 * breathe), radius: 10)
            }
        }
        .frame(width: 260, height: 220)
    }
}

// MARK: - 2. Rooms — a mini dashboard being used

private struct RoomsArt: View {
    let accent: Color
    let t: Double

    private static let rooms: [(icon: String, name: String)] = [
        ("sofa.fill", "Living Room"), ("bed.double.fill", "Bedroom"),
        ("fork.knife", "Kitchen"), ("tv.fill", "Media Den"),
    ]

    var body: some View {
        // 6s story: tap ring → room lights up → brightness scrubs up.
        let p = TourMotionMath.wrap(t, period: 6.0)
        let tapRing = TourMotionMath.segment(p, from: 0.04, to: 0.16) * (1 - TourMotionMath.segment(p, from: 0.16, to: 0.30))
        let lit = TourMotionMath.segment(p, from: 0.12, to: 0.22)
        let bright = 0.2 + 0.6 * TourMotionMath.segment(p, from: 0.30, to: 0.55)
        let washHue = TourMotionMath.wrap(t, period: 9.0)

        LazyVGrid(columns: [GridItem(.fixed(120)), GridItem(.fixed(120))], spacing: 10) {
            ForEach(0..<4, id: \.self) { i in
                MockCard(glow: i == 0 ? lit : 0, accent: accent) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: Self.rooms[i].icon)
                                .font(.system(size: 14))
                                .foregroundStyle(cardTint(i, washHue: washHue, lit: lit))
                            Spacer()
                            if i == 0 {
                                Circle()
                                    .strokeBorder(accent.opacity(tapRing), lineWidth: 2)
                                    .frame(width: 18, height: 18)
                            }
                        }
                        Text(Self.rooms[i].name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StagePalette.ink.opacity(0.9))
                            .lineLimit(1)
                        MockSlider(fraction: i == 0 ? bright : [0.0, 0.45, 0.7, 0.3][i], accent: accent)
                    }
                }
            }
        }
        .frame(width: 260)
    }

    private func cardTint(_ i: Int, washHue: Double, lit: Double) -> Color {
        if i == 3 { return Color(hue: washHue, saturation: 0.7, brightness: 0.95) }
        if i == 0 { return HuePalette.amber.opacity(0.4 + 0.6 * lit) }
        return StagePalette.muted
    }
}

// MARK: - 3. Moods — preset chips retuning a room glow

private struct MoodsArt: View {
    let accent: Color
    let t: Double

    // The four real presets (LightingPreset.all order) + their glow character.
    private static let chips: [(icon: String, name: String, glow: Color)] = [
        ("bolt.fill", "Energize", Color(hex: "#CFE8FF")),
        ("book.fill", "Read", Color(hex: "#FFE3B8")),
        ("moon.stars.fill", "Relax", Color(hex: "#FFB35C")),
        ("zzz", "Sleep", Color(hex: "#B45D1F")),
    ]

    var body: some View {
        let active = TourMotionMath.hop(t, count: 4, period: 1.9)
        let blend = TourMotionMath.ease(TourMotionMath.wrap(t, period: 1.9))
        let previous = (active + 3) % 4
        let glowColor = Self.chips[previous].glow.tourMix(with: Self.chips[active].glow, by: blend)

        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(spacing: 4) {
                        Image(systemName: Self.chips[i].icon)
                            .font(.system(size: 14))
                        Text(Self.chips[i].name)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(i == active ? StagePalette.ink : StagePalette.muted)
                    .frame(width: 56, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(tourSurface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(i == active ? accent : StagePalette.line, lineWidth: i == active ? 1.5 : 1)
                    )
                }
            }
            Capsule()
                .fill(glowColor.opacity(0.85))
                .frame(width: 236, height: 26)
                .blur(radius: 6)
                .overlay(Capsule().strokeBorder(StagePalette.line, lineWidth: 1))
        }
        .frame(width: 264)
    }
}

// MARK: - 4. Room detail — copy a color, paint it across lights

private struct RoomDetailArt: View {
    let accent: Color
    let t: Double

    var body: some View {
        // 7s story: a color lifts off light 1, lands on light 3, then a paint
        // sweep tints everything; My Colors waits below.
        let p = TourMotionMath.wrap(t, period: 7.0)
        let travel = TourMotionMath.segment(p, from: 0.12, to: 0.40)
        let landed = p > 0.40 && p < 0.55
        let sweep = TourMotionMath.segment(p, from: 0.55, to: 0.88)
        let copied = Color(hue: 0.78, saturation: 0.7, brightness: 0.95)
        let baseDots: [Color] = [copied, Color(hex: "#FFD9A0"), Color(hex: "#9FE2FF")]

        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                let painted = sweep > Double(i) / 3 + 0.15
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(StagePalette.muted)
                    Text("Light \(i + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StagePalette.ink.opacity(0.85))
                    Spacer()
                    Circle()
                        .fill(painted ? accent : ((i == 2 && (landed || p >= 0.55)) ? copied : baseDots[i]))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                }
                .padding(.horizontal, 12)
                .frame(width: 240, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(tourSurface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StagePalette.line, lineWidth: 1))
            }
            HStack(spacing: 8) {
                MonoTag(text: "MY COLORS")
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(Color(hue: [0.05, 0.55, 0.78, 0.32][i], saturation: 0.7, brightness: 0.95))
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 240, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            // The traveling copy droplet, room row 1 → row 3.
            Circle()
                .fill(copied)
                .frame(width: 14, height: 14)
                .shadow(color: copied.opacity(0.8), radius: 5)
                .offset(x: -20, y: 13 + 100 * travel)
                .opacity(travel > 0 && travel < 1 ? 1 : 0)
        }
        .frame(width: 264)
    }
}

// MARK: - 5. Scenes — a starred library, one scene moving rooms

private struct ScenesArt: View {
    let accent: Color
    let t: Double
    let live: Bool

    var body: some View {
        // A scene card slides from LIVING ROOM to BEDROOM and back (10s).
        let p = TourMotionMath.wrap(t, period: 10.0)
        let toRight = TourMotionMath.segment(p, from: 0.15, to: 0.40)
        let toLeft = TourMotionMath.segment(p, from: 0.65, to: 0.90)
        let slide = toRight - toLeft   // 0 = left column, 1 = right column

        VStack(spacing: 12) {
            HStack(spacing: 44) {
                MonoTag(text: "LIVING ROOM")
                MonoTag(text: "BEDROOM")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    sceneCard(name: "Golden Hour", starred: true) {
                        LinearGradient(colors: [Color(hex: "#FFB35C"), Color(hex: "#FF6B6B")],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 8)
                            .clipShape(Capsule())
                    }
                    sceneCard(name: "Ocean Drift", starred: false) {
                        PatternStripView(pattern: .wave, accent: Color(hex: "#40C9FF"), animated: live)
                    }
                }
                VStack(spacing: 10) {
                    sceneCard(name: "Forest Calm", starred: false) {
                        LinearGradient(colors: [Color(hex: "#3FA65C"), Color(hex: "#9BE29B")],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 8)
                            .clipShape(Capsule())
                    }
                    Color.clear.frame(width: 116, height: 54)
                }
            }
            .overlay(alignment: .topLeading) {
                sceneCard(name: "Neon Nights", starred: false) {
                    LinearGradient(colors: [accent, Color(hex: "#668AFF")],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 8)
                        .clipShape(Capsule())
                }
                .offset(x: 132 * slide, y: 64)
                .shadow(color: .black.opacity(0.3 * TourMotionMath.pulse(slide, period: 2)), radius: 8)
            }
        }
        .frame(width: 264)
    }

    @ViewBuilder
    private func sceneCard(name: String, starred: Bool, @ViewBuilder strip: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StagePalette.ink.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(HuePalette.amber)
                }
            }
            strip()
        }
        .padding(8)
        .frame(width: 116)
        .background(RoundedRectangle(cornerRadius: 10).fill(tourSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StagePalette.line, lineWidth: 1))
    }
}

// MARK: - 6. Studio — three decks, a live card, a mixer being tuned

private struct StudioArt: View {
    let accent: Color
    let t: Double
    let live: Bool

    private static let decks = ["EFFECTS", "LIVE", "COMPOSER"]

    var body: some View {
        let deck = TourMotionMath.hop(t, count: 3, period: 2.5)
        let thumbA = 0.3 + 0.35 * TourMotionMath.pulse(t, period: 4.0)
        let thumbB = 0.65 - 0.35 * TourMotionMath.pulse(t, period: 5.0)

        VStack(spacing: 14) {
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 4) {
                        MonoTag(text: Self.decks[i], color: i == deck ? accent : StagePalette.muted)
                        Capsule()
                            .fill(accent)
                            .frame(width: 26, height: 2)
                            .opacity(i == deck ? 1 : 0)
                    }
                }
            }
            MockCard(glow: 0.35, accent: accent) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Candlelight Chase")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StagePalette.ink)
                        Spacer()
                        MonoTag(text: "LIVE", color: Color(hex: "#40D9BF"))
                    }
                    PatternStripView(pattern: .chase, accent: accent, animated: live)
                    HStack(spacing: 10) {
                        MonoTag(text: "SPEED")
                        MockSlider(fraction: thumbA, accent: accent)
                    }
                    HStack(spacing: 10) {
                        MonoTag(text: "GLOW ")
                        MockSlider(fraction: thumbB, accent: accent)
                    }
                }
            }
            .frame(width: 250)
        }
        .frame(width: 264)
    }
}

// MARK: - 7. Composer — palette, motion, and reaction layered into a scene

private struct ComposerArt: View {
    let accent: Color
    let t: Double
    let live: Bool

    var body: some View {
        // 8s story: three layers assemble, then the save pill lands.
        let p = TourMotionMath.wrap(t, period: 8.0)
        let l0 = TourMotionMath.segment(p, from: 0.02, to: 0.14)
        let l1 = TourMotionMath.segment(p, from: 0.14, to: 0.26)
        let l2 = TourMotionMath.segment(p, from: 0.26, to: 0.38)
        let saved = TourMotionMath.segment(p, from: 0.72, to: 0.84)

        VStack(spacing: 10) {
            layerChip(tag: "PALETTE", reveal: l0) {
                LinearGradient(colors: [Color(hex: "#FF6B6B"), accent, Color(hex: "#40C9FF")],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10)
                    .clipShape(Capsule())
            }
            layerChip(tag: "MOTION", reveal: l1) {
                PatternStripView(pattern: .comet, accent: accent, animated: live)
            }
            layerChip(tag: "REACTION", reveal: l2) {
                HStack(spacing: 5) {
                    ForEach(0..<9, id: \.self) { i in
                        let h = 0.25 + 0.75 * TourMotionMath.pulse(t + Double(i) * 0.35, period: 2.2)
                        Capsule()
                            .fill(accent.opacity(0.85))
                            .frame(width: 5, height: 6 + 16 * h)
                    }
                }
                .frame(height: 24, alignment: .bottom)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Saved to your deck")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(hex: "#40D9BF"))
            .opacity(saved)
        }
        .frame(width: 250)
    }

    @ViewBuilder
    private func layerChip(tag: String, reveal: Double, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            MonoTag(text: tag)
                .frame(width: 68, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tourSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StagePalette.line, lineWidth: 1))
        .opacity(0.15 + 0.85 * reveal)
        .offset(x: 24 * (1 - reveal))
    }
}

// MARK: - 8. Perform — decks, crossfader, punch pads on the beat

private struct PerformArt: View {
    let accent: Color
    let t: Double

    var body: some View {
        // Crossfader glides A↔B on a 6s sine; pads pulse round-robin on a
        // 0.75s grid (≤1.33Hz, never two at once).
        let x = TourMotionMath.pulse(t, period: 6.0)   // 0 = deck A, 1 = deck B
        let pad = TourMotionMath.hop(t, count: 4, period: 0.75)
        let padGlow = TourMotionMath.pulse(t, period: 0.75)

        VStack(spacing: 14) {
            HStack(spacing: 14) {
                deckSquare("A", energy: 1 - x)
                VStack(spacing: 5) {
                    MonoTag(text: "120 BPM", color: accent)
                    ZStack(alignment: .leading) {
                        Capsule().fill(StagePalette.raised).frame(width: 90, height: 5)
                        Circle().fill(StagePalette.ink)
                            .frame(width: 14, height: 14)
                            .offset(x: 76 * x)
                    }
                    MonoTag(text: "CROSSFADE")
                }
                deckSquare("B", energy: x)
            }
            LazyVGrid(columns: [GridItem(.fixed(52)), GridItem(.fixed(52)), GridItem(.fixed(52)), GridItem(.fixed(52))], spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(i == pad ? accent.opacity(0.25 + 0.45 * padGlow) : tourSurface)
                        .frame(height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(i == pad ? accent.opacity(0.8) : StagePalette.line, lineWidth: 1)
                        )
                }
            }
        }
        .frame(width: 264)
    }

    @ViewBuilder
    private func deckSquare(_ label: String, energy: Double) -> some View {
        Text(label)
            .font(HueFont.stageValue)
            .foregroundStyle(StagePalette.ink.opacity(0.5 + 0.5 * energy))
            .frame(width: 54, height: 54)
            .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08 + 0.3 * energy)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accent.opacity(0.25 + 0.6 * energy), lineWidth: 1.5)
            )
    }
}

// MARK: - 9. Automations — a day of light on one arc

private struct AutomationsArt: View {
    let accent: Color
    let t: Double

    var body: some View {
        // The sun dot walks sunrise → sunset over 8s; light warms with it.
        let p = TourMotionMath.wrap(t, period: 8.0)
        let e = TourMotionMath.ease(p)
        let warm = Color(hex: "#CFE8FF").tourMix(with: Color(hex: "#FF8A3D"), by: e)
        let arcW = 200.0, arcH = 74.0

        VStack(spacing: 16) {
            ZStack {
                ArcShape()
                    .stroke(StagePalette.line, style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                    .frame(width: arcW, height: arcH)
                Circle()
                    .fill(warm)
                    .frame(width: 16, height: 16)
                    .shadow(color: warm.opacity(0.9), radius: 8)
                    .offset(x: arcW * (e - 0.5), y: -arcH * sin(.pi * e) + arcH / 2)
                HStack {
                    Image(systemName: "sunrise.fill")
                    Spacer()
                    Image(systemName: "sunset.fill")
                }
                .font(.system(size: 15))
                .foregroundStyle(StagePalette.muted)
                .frame(width: arcW + 44)
                .offset(y: arcH / 2 + 4)
            }
            .frame(height: arcH + 30)
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 10))
                MonoTag(text: "07:00 · WAKE UP", color: StagePalette.ink.opacity(0.8))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(tourSurface))
            .overlay(Capsule().strokeBorder(StagePalette.line, lineWidth: 1))
        }
        .frame(width: 264)
    }

    private struct ArcShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                              control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
            return path
        }
    }
}

// MARK: - 10. Family — an invite crossing phones, rooms being granted

private struct FamilyArt: View {
    let accent: Color
    let t: Double

    // Deterministic QR-ish 5×5 glyph (no randomness — resume-safe, test-safe).
    private static let qrBits: [[Bool]] = [
        [true,  true,  false, true,  true ],
        [true,  false, true,  false, true ],
        [false, true,  true,  true,  false],
        [true,  false, true,  false, true ],
        [true,  true,  false, true,  true ],
    ]

    private static let grants = ["Living Room", "Kitchen", "Bedroom"]

    var body: some View {
        let p = TourMotionMath.wrap(t, period: 9.0)
        let beam = TourMotionMath.segment(p, from: 0.08, to: 0.34)

        VStack(spacing: 16) {
            HStack(spacing: 22) {
                phone(active: 1 - beam)
                VStack(spacing: 4) {
                    qrGlyph
                    MonoTag(text: "INVITE")
                }
                phone(active: beam)
            }
            .overlay {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: accent.opacity(0.9), radius: 5)
                    .offset(x: -70 + 140 * beam)
                    .opacity(beam > 0.02 && beam < 0.98 ? 1 : 0)
            }
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    let granted = p > 0.42 + Double(i) * 0.14
                    HStack(spacing: 4) {
                        Text(Self.grants[i])
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(granted ? StagePalette.ink : StagePalette.muted)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(hex: "#40D9BF"))
                            .opacity(granted ? 1 : 0.15)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tourSurface))
                    .overlay(Capsule().strokeBorder(granted ? accent.opacity(0.5) : StagePalette.line, lineWidth: 1))
                }
            }
        }
        .frame(width: 280)
    }

    private var qrGlyph: some View {
        VStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Self.qrBits[r][c] ? StagePalette.ink : .clear)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(tourSurface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StagePalette.line, lineWidth: 1))
    }

    @ViewBuilder
    private func phone(active: Double) -> some View {
        Image(systemName: "iphone")
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(StagePalette.ink.opacity(0.35 + 0.6 * active))
            .shadow(color: accent.opacity(0.5 * active), radius: 8)
    }
}

// MARK: - 11. Everywhere — Siri, widgets, and the watch orbit one home

private struct EverywhereArt: View {
    let accent: Color
    let t: Double

    private static let satellites: [(icon: String, tag: String)] = [
        ("waveform", "SIRI"), ("square.grid.2x2.fill", "WIDGETS"), ("applewatch", "WATCH"),
    ]

    var body: some View {
        let active = TourMotionMath.hop(t, count: 3, period: 2.0)
        let glow = TourMotionMath.pulse(t, period: 2.0)

        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let angle = -.pi / 2 + 2 * .pi * Double(i) / 3
                let hot = i == active
                VStack(spacing: 4) {
                    Image(systemName: Self.satellites[i].icon)
                        .font(.system(size: 22))
                        .foregroundStyle(hot ? accent : StagePalette.muted)
                        .shadow(color: accent.opacity(hot ? 0.5 * glow : 0), radius: 7)
                    MonoTag(text: Self.satellites[i].tag, color: hot ? accent : StagePalette.muted)
                }
                .offset(x: 96 * cos(angle), y: 78 * sin(angle))
            }
            ZStack {
                Circle()
                    .fill(tourSurface)
                    .frame(width: 66, height: 66)
                    .overlay(Circle().strokeBorder(StagePalette.line, lineWidth: 1))
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(HuePalette.amber)
            }
        }
        .frame(width: 264, height: 210)
    }
}

// MARK: - 12. Wrap — a quiet promise

private struct WrapArt: View {
    let accent: Color
    let t: Double

    private static let rows = ["3 FLASHES/SEC CAP", "LOCAL-ONLY CONTROL", "REPLAY FROM MORE"]

    var body: some View {
        let breathe = TourMotionMath.pulse(t, period: 4.0)

        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 46))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.25 + 0.3 * breathe), radius: 14)
            VStack(spacing: 8) {
                ForEach(Self.rows, id: \.self) { row in
                    MonoTag(text: row, color: StagePalette.ink.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(tourSurface))
                        .overlay(Capsule().strokeBorder(StagePalette.line, lineWidth: 1))
                }
            }
        }
        .frame(width: 264)
    }
}

// MARK: - Color blending helper

private extension Color {
    /// Linear blend in sRGB via UIColor. Named tourMix to avoid colliding with
    /// SwiftUI's iOS-18 Color.mix (deployment target is 17).
    func tourMix(with other: Color, by fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * f,
                     green: g1 + (g2 - g1) * f,
                     blue: b1 + (b2 - b1) * f)
        .opacity(a1 + (a2 - a1) * f)
    }
}

#Preview("Tour Illustrations") {
    ScrollView {
        VStack(spacing: 28) {
            ForEach(TutorialPage.Illustration.allCases, id: \.self) { kind in
                VStack(spacing: 8) {
                    Text(kind.rawValue).font(HueFont.stageTag).foregroundStyle(StagePalette.muted)
                    TutorialIllustrationView(kind: kind, accent: HuePalette.amber, isActive: true)
                        .frame(height: 230)
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
    .background(StagePalette.stage)
    .preferredColorScheme(.dark)
}
