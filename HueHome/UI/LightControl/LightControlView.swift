// LightControlView.swift
// HueHome Pro — Epic 3 / Story 3.3
//
// Full-screen individual light controller.
// Capabilities detected at runtime:
//   • supportsColor     → color wheel (CIE xy via HueColorUtils)
//   • supportsColorTemp → colour-temperature gradient slider (mirek)
//   • always            → brightness scrubber + on/off toggle
//
// All changes are optimistic — UI updates immediately, API called on gesture end.
// Haptic feedback mirrors the room-level brightness scrubber pattern.

import SwiftUI

// MARK: - LightControlView

struct LightControlView: View {

    @Binding var light: LightDisplayItem
    let onToggle:    () -> Void
    let onBrightness: (Double) -> Void
    let onColor:      (Double, Double) -> Void      // x, y
    let onColorTemp:  (Int) -> Void                 // mirek

    // Local in-progress state (committed on gesture end)
    @State private var liveHue:        Double = 0
    @State private var liveSaturation: Double = 0
    @State private var liveMirek:      Int    = 300

    private var glowColor: Color {
        guard light.supportsColor, let x = light.colorX, let y = light.colorY else {
            return Color(red: 1.0, green: 0.76, blue: 0.2)
        }
        return HueColorUtils.color(fromX: x, y: y, brightness: light.brightness)
    }

    var body: some View {
        ZStack {
            ambientBackground
            ScrollView {
                VStack(spacing: 28) {
                    // ── On/Off + name ──────────────────────
                    controlHeader

                    // ── Color wheel (color-capable lights) ─
                    if light.supportsColor {
                        colorSection
                    }

                    // ── Colour temp slider ─────────────────
                    if light.supportsColorTemp {
                        colorTempSection
                    }

                    // ── Brightness ─────────────────────────
                    brightnessSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(light.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Power toggle in toolbar — always reliable, no clipping/gesture conflicts.
                Button {
                    HapticManager.shared.medium()
                    onToggle()
                } label: {
                    Image(systemName: light.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.55))
                        .symbolEffect(.bounce, value: light.isOn)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { syncLocalState() }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            if light.isOn {
                Circle()
                    .fill(RadialGradient(
                        colors: [glowColor.opacity(0.30), .clear],
                        center: .center, startRadius: 0, endRadius: 220
                    ))
                    .frame(width: 400)
                    .blur(radius: 30)
                    .animation(.easeInOut(duration: 0.5), value: glowColor.description)
            }
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Header
    // ──────────────────────────────────────────────

    private var controlHeader: some View {
        GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
            HStack(spacing: 16) {
                // Archetype icon
                ZStack {
                    Circle()
                        .fill(light.isOn ? glowColor.opacity(0.22) : Color.white.opacity(0.07))
                        .frame(width: 52, height: 52)
                    Image(systemName: archetypeIcon(for: light.archetype))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.4))
                        .symbolEffect(.pulse, value: light.isOn)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(light.isOn ? "On" : "Off")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.55))
                    HStack(spacing: 4) {
                        if light.supportsColor    { capBadge("Color") }
                        if light.supportsColorTemp { capBadge("Color Temp") }
                        if !light.supportsColor && !light.supportsColorTemp {
                            capBadge("Brightness")
                        }
                    }
                }

                Spacer()

                // State indicator dot (power button is in the toolbar)
                Circle()
                    .fill(light.isOn ? glowColor : Color.white.opacity(0.2))
                    .frame(width: 10, height: 10)
                    .shadow(color: light.isOn ? glowColor.opacity(0.9) : .clear, radius: 8)
            }
        }
        .frame(height: 88)
    }

    private func capBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Wheel
    // ──────────────────────────────────────────────

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Color")
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                ColorWheelView(
                    hue: $liveHue,
                    saturation: $liveSaturation
                ) { h, s in
                    // Commit: convert HSB → xy and call API
                    let (x, y) = HueColorUtils.xyFrom(hue: h, saturation: s, brightness: 1)
                    // Optimistic: update light model's xy
                    light.colorX = x
                    light.colorY = y
                    HapticManager.shared.heavy()
                    onColor(x, y)
                }
                .frame(width: 220, height: 220)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Temperature Slider
    // ──────────────────────────────────────────────

    private var colorTempSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let kelvin = HueColorUtils.kelvin(from: liveMirek)
            sectionLabel("Color Temperature · \(kelvin)K")
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                ColorTempSlider(
                    mirek: $liveMirek,
                    mirekMin: light.mirekMin,
                    mirekMax: light.mirekMax
                ) { mirek in
                    light.colorTempMirek = mirek
                    HapticManager.shared.heavy()
                    onColorTemp(mirek)
                }
                .padding(.vertical, 16)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Brightness
    // ──────────────────────────────────────────────

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Brightness · \(Int(light.brightness))%")
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                BrightnessRow(
                    brightness: $light.brightness,
                    glowColor: glowColor,
                    onCommit: { onBrightness(light.brightness) }
                )
                .padding(.vertical, 16)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.leading, 4)
    }

    private func syncLocalState() {
        if let x = light.colorX, let y = light.colorY {
            let (h, s, _) = HueColorUtils.hsb(fromX: x, y: y, brightness: light.brightness)
            liveHue = h
            liveSaturation = s
        }
        liveMirek = light.colorTempMirek ?? ((light.mirekMin + light.mirekMax) / 2)
    }
}

// MARK: - ColorWheelView

struct ColorWheelView: View {

    @Binding var hue: Double
    @Binding var saturation: Double
    let onCommit: (Double, Double) -> Void

    @State private var thumbPos: CGPoint = .zero
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2 - 14
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                // ── Hue wheel ────────────────────────
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0/12).map {
                            Color(hue: $0, saturation: 1, brightness: 1)
                        }),
                        center: .center
                    ))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                // ── White radial overlay (saturation) ─
                Circle()
                    .fill(RadialGradient(
                        colors: [.white, .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    ))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                // ── Outer ring border ─────────────────
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                // ── Thumb ─────────────────────────────
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: isDragging ? 28 : 22, height: isDragging ? 28 : 22)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5)
                        .shadow(color: .black.opacity(0.3), radius: 3))
                    .shadow(color: Color(hue: hue, saturation: 1, brightness: 1).opacity(0.6),
                            radius: isDragging ? 10 : 5)
                    .position(thumbPos)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDragging)
            }
            .contentShape(Circle().path(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            HapticManager.shared.medium()
                        }
                        pick(at: value.location, center: center, radius: radius)
                    }
                    .onEnded { value in
                        pick(at: value.location, center: center, radius: radius)
                        isDragging = false
                        HapticManager.shared.heavy()
                        onCommit(hue, saturation)
                    }
            )
            .onAppear { placeThumb(center: center, radius: radius) }
            .onChange(of: hue) { _, _ in placeThumb(center: center, radius: radius) }
        }
    }

    private func pick(at location: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let dist = min(sqrt(dx*dx + dy*dy), radius)
        let angle = atan2(dy, dx)
        hue = ((angle / (2 * .pi)) + 1).truncatingRemainder(dividingBy: 1)
        saturation = dist / radius
        thumbPos = CGPoint(x: center.x + cos(angle) * dist,
                           y: center.y + sin(angle) * dist)
    }

    private func placeThumb(center: CGPoint, radius: CGFloat) {
        let angle = hue * 2 * .pi
        let dist  = saturation * radius
        thumbPos = CGPoint(x: center.x + cos(angle) * dist,
                           y: center.y + sin(angle) * dist)
    }
}

// MARK: - ColorTempSlider

struct ColorTempSlider: View {

    @Binding var mirek: Int
    let mirekMin: Int
    let mirekMax: Int
    let onCommit: (Int) -> Void

    @State private var isDragging  = false
    @State private var sliderValue: Double = 0.5
    @State private var lastNotch: Int = 0

    var body: some View {
        VStack(spacing: 10) {
            // Gradient track + thumb
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Gradient background
                    LinearGradient(gradient: HueColorUtils.colorTempGradient,
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        .frame(height: 8)

                    // Thumb
                    let thumbX = sliderValue * geo.size.width
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 28 : 22, height: isDragging ? 28 : 22)
                        .shadow(radius: isDragging ? 8 : 4)
                        .offset(x: max(0, min(thumbX - (isDragging ? 14 : 11), geo.size.width - (isDragging ? 28 : 22))))
                        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isDragging)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                HapticManager.shared.medium()
                            }
                            let raw = value.location.x / geo.size.width
                            sliderValue = min(1, max(0, raw))
                            let newMirek = HueColorUtils.mirek(fromSlider: sliderValue, min: mirekMin, max: mirekMax)
                            // Haptic every ~200K change
                            let notch = newMirek / 100
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                            mirek = newMirek
                        }
                        .onEnded { _ in
                            isDragging = false
                            HapticManager.shared.heavy()
                            onCommit(mirek)
                        }
                )
            }
            .frame(height: 28)

            // Labels
            HStack {
                Text("🕯 Warm").font(.caption2).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("☀ Cool").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            sliderValue = HueColorUtils.sliderValue(mirek: mirek, min: mirekMin, max: mirekMax)
            lastNotch = mirek / 100
        }
    }
}
