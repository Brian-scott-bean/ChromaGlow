// LightControlView.swift
// CastChroma — Epic 3 / Story 3.3
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
import CoreGraphics

// MARK: - LightControlView

struct LightControlView: View {

    @Binding var light: LightDisplayItem
    let onToggle:    (Bool) -> Void   // Bool = desired new on-state
    let onBrightness: (Double) -> Void
    let onColor:      (Double, Double) -> Void      // x, y
    let onColorTemp:  (Int) -> Void                 // mirek
    /// Round 3 (D): bridge-native identify flash. Optional so hosts without
    /// a bridge context (previews, demo) simply don't show the button.
    var onIdentify:   (() -> Void)? = nil

    // Local in-progress state (committed on gesture end)
    @State private var liveHue:        Double = 0
    @State private var liveSaturation: Double = 0
    @State private var liveMirek:      Int    = 300
    @State private var selectedSwatch: Int?   = nil  // index into ColorSwatch.presets

    // Cached glow colour — recomputed only on light change, not on every render.
    // Prevents ambientBackground blur from being re-composited during drag.
    private var glowColor: Color {
        guard light.supportsColor, let x = light.colorX, let y = light.colorY else {
            return Color(red: 1.0, green: 0.76, blue: 0.2)
        }
        return HueColorUtils.color(fromX: x, y: y, brightness: light.brightness)
    }

    // Local brightness state for optimistic display before SSE confirms.
    // Updated by BrightnessRow.onCommit — never written during drag.
    @State private var displayBrightness: Double = 0

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
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let onIdentify {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Free bridge signaling: 3 s flash, self-terminating.
                    Button {
                        HapticManager.shared.light()
                        onIdentify()
                    } label: {
                        Image(systemName: "light.beacon.max")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .accessibilityLabel("Flash to identify")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // Power toggle in toolbar — always reliable, no clipping/gesture conflicts.
                Button {
                    HapticManager.shared.medium()
                    onToggle(!light.isOn)   // light is @Binding — reads current vm.lights[idx]
                } label: {
                    Image(systemName: light.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.55))
                        .symbolEffect(.bounce, value: light.isOn)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            syncLocalState()
            displayBrightness = light.brightness
        }
        .onChange(of: light.brightness) { _, new in displayBrightness = new }
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
                VStack(spacing: 20) {
                    ColorWheelView(
                        hue: $liveHue,
                        saturation: $liveSaturation
                    ) { h, s in
                        // Commit: convert HSB → xy and call API
                        let (x, y) = HueColorUtils.xyFrom(hue: h, saturation: s, brightness: 1)
                        light.colorX = x
                        light.colorY = y
                        selectedSwatch = ColorSwatch.nearest(hue: h, saturation: s)
                        HapticManager.shared.heavy()
                        onColor(x, y)
                    }
                    .frame(width: 220, height: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    // ── Quick color presets ─────────────────────
                    Divider().background(Color.white.opacity(0.08))
                    colorSwatchRow

                    // ── My Colors (saved palette) ───────────────
                    Divider().background(Color.white.opacity(0.08))
                    myColorsRow
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// Saved palette: ＋ captures the light's current look (color + brightness);
    /// tapping a swatch applies it with the light's capability fallback.
    private var myColorsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MY COLORS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 16)
            SavedColorStrip(
                onSave: {
                    let (x, y) = HueColorUtils.xyFrom(
                        hue: liveHue, saturation: liveSaturation, brightness: 1
                    )
                    SavedColorStore.shared.add(SavedColor(
                        x: x, y: y, brightness: displayBrightness
                    ))
                    HapticManager.shared.success()
                },
                onTapSwatch: { applySavedColor($0) }
            )
        }
    }

    private func applySavedColor(_ saved: SavedColor) {
        switch saved.application(
            supportsColor: light.supportsColor,
            supportsColorTemp: light.supportsColorTemp,
            mirekMin: light.mirekMin,
            mirekMax: light.mirekMax
        ) {
        case .color(let x, let y, let brightness):
            let (h, s, _) = HueColorUtils.hsb(fromX: x, y: y, brightness: brightness)
            liveHue = h
            liveSaturation = s
            selectedSwatch = nil
            light.colorX = x
            light.colorY = y
            onColor(x, y)
            commitSavedBrightness(brightness)
        case .colorTemp(let mirek, let brightness):
            liveMirek = mirek
            light.colorTempMirek = mirek
            onColorTemp(mirek)
            commitSavedBrightness(brightness)
        case .brightnessOnly(let brightness):
            commitSavedBrightness(brightness)
        }
        HapticManager.shared.heavy()
    }

    private func commitSavedBrightness(_ brightness: Double) {
        displayBrightness = brightness
        light.brightness = brightness
        onBrightness(brightness)
    }

    private var colorSwatchRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(ColorSwatch.presets.enumerated()), id: \.offset) { i, swatch in
                    Button {
                        HapticManager.shared.medium()
                        liveHue        = swatch.hue
                        liveSaturation = swatch.saturation
                        selectedSwatch = i
                        let (x, y) = HueColorUtils.xyFrom(
                            hue: swatch.hue, saturation: swatch.saturation, brightness: 1
                        )
                        light.colorX = x
                        light.colorY = y
                        HapticManager.shared.heavy()
                        onColor(x, y)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 32, height: 32)
                                .shadow(color: swatch.color.opacity(0.6), radius: 4)
                            if selectedSwatch == i {
                                Circle()
                                    .stroke(.white, lineWidth: 2.5)
                                    .frame(width: 36, height: 36)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Temperature Slider
    // ──────────────────────────────────────────────

    private var colorTempSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // liveMirek is updated only by onCommit — not during drag.
            let kelvin = HueColorUtils.kelvin(from: liveMirek)
            sectionLabel("Color Temperature · \(kelvin)K")
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                VStack(spacing: 12) {
                    ColorTempSlider(
                        currentMirek: liveMirek,
                        mirekMin: light.mirekMin,
                        mirekMax: light.mirekMax
                    ) { mirek in
                        liveMirek = mirek                // update label once on release
                        light.colorTempMirek = mirek     // optimistic model update
                        HapticManager.shared.heavy()
                        onColorTemp(mirek)
                    }
                    .padding(.top, 16)

                    // CT-only lights have no color section — give them their
                    // own My Colors row so warm/cool whites are saveable too.
                    if !light.supportsColor {
                        Divider().background(Color.white.opacity(0.08))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MY COLORS")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.0)
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 16)
                            SavedColorStrip(
                                onSave: {
                                    SavedColorStore.shared.add(SavedColor(
                                        mirek: liveMirek, brightness: displayBrightness
                                    ))
                                    HapticManager.shared.success()
                                },
                                onTapSwatch: { applySavedColor($0) }
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Brightness
    // ──────────────────────────────────────────────

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Label shows the committed value — updated by onCommit, not during drag.
            // Avoids re-rendering the GlassmorphicCard on every drag tick.
            sectionLabel("Brightness · \(Int(displayBrightness))%")
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                BrightnessRow(
                    brightness: light.brightness,   // read-only snapshot
                    glowColor: glowColor,
                    onCommit: { newBrightness in
                        displayBrightness = newBrightness    // update label once on release
                        light.brightness  = newBrightness    // optimistic model update
                        onBrightness(newBrightness)          // fire API
                    }
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
            selectedSwatch = ColorSwatch.nearest(hue: h, saturation: s)
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
        let dist: CGFloat = min(sqrt(dx * dx + dy * dy), radius)
        let angle: CGFloat = atan2(dy, dx)
        let normalizedHue = ((angle / (2 * .pi)) + 1)
            .truncatingRemainder(dividingBy: 1)

        hue = Double(normalizedHue)
        saturation = Double(dist / radius)

        thumbPos = CGPoint(
            x: center.x + CoreGraphics.cos(angle) * dist,
            y: center.y + CoreGraphics.sin(angle) * dist
        )
    }

    private func placeThumb(center: CGPoint, radius: CGFloat) {
        let angle: CGFloat = CGFloat(hue) * 2 * .pi
        let dist: CGFloat = CGFloat(saturation) * radius

        thumbPos = CGPoint(
            x: center.x + CoreGraphics.cos(angle) * dist,
            y: center.y + CoreGraphics.sin(angle) * dist
        )
    }
}

// MARK: - ColorTempSlider
//
// Performance contract: currentMirek is a read-only seed value.
// All in-flight drag state is kept in @State var localMirek.
// Zero writes propagate to the parent LightControlView during drag.
// onCommit fires ONCE when the finger lifts.

struct ColorTempSlider: View {

    let currentMirek: Int    // seed; used on appear + external sync
    let mirekMin: Int
    let mirekMax: Int
    let onCommit: (Int) -> Void

    @State private var isDragging:   Bool   = false
    @State private var sliderValue:  Double = 0.5
    @State private var localMirek:   Int    = 300   // in-flight drag value
    @State private var lastNotch:    Int    = 0

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(gradient: HueColorUtils.colorTempGradient,
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        .frame(height: 8)

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
                            let notch = newMirek / 100
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                            localMirek = newMirek   // ← pure @State, no parent cascade
                        }
                        .onEnded { _ in
                            isDragging = false
                            onCommit(localMirek)    // ← ONE write to parent on finger lift
                        }
                )
            }
            .frame(height: 28)

            HStack {
                Text("🕯 Warm").font(.caption2).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("☀ Cool").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            sliderValue = HueColorUtils.sliderValue(mirek: currentMirek, min: mirekMin, max: mirekMax)
            localMirek  = currentMirek
            lastNotch   = currentMirek / 100
        }
        // Sync when parent commits a new value (SSE update)
        .onChange(of: currentMirek) { _, new in
            if !isDragging {
                sliderValue = HueColorUtils.sliderValue(mirek: new, min: mirekMin, max: mirekMax)
                localMirek  = new
            }
        }
    }
}



// MARK: - Color Swatches

/// Named HSB color presets for the quick-pick tray in LightControlView.
/// hue/saturation drive both the UI swatch circle and the API call via xyFrom().
struct ColorSwatch {
    let name: String
    let hue: Double         // SwiftUI 0–1
    let saturation: Double  // 0–1

    var color: Color { Color(hue: hue, saturation: saturation, brightness: 1.0) }

    static let presets: [ColorSwatch] = [
        ColorSwatch(name: "Red",        hue: 0.0,    saturation: 1.0),
        ColorSwatch(name: "Orange",     hue: 0.067,  saturation: 1.0),
        ColorSwatch(name: "Yellow",     hue: 0.135,  saturation: 1.0),
        ColorSwatch(name: "Lime",       hue: 0.225,  saturation: 1.0),
        ColorSwatch(name: "Green",      hue: 0.330,  saturation: 1.0),
        ColorSwatch(name: "Teal",       hue: 0.490,  saturation: 1.0),
        ColorSwatch(name: "Blue",       hue: 0.625,  saturation: 1.0),
        ColorSwatch(name: "Indigo",     hue: 0.700,  saturation: 1.0),
        ColorSwatch(name: "Purple",     hue: 0.765,  saturation: 1.0),
        ColorSwatch(name: "Magenta",    hue: 0.850,  saturation: 1.0),
        ColorSwatch(name: "Pink",       hue: 0.920,  saturation: 0.70),
        ColorSwatch(name: "White",      hue: 0.110,  saturation: 0.06),
    ]

    /// Returns the index of the nearest preset to the given hue/saturation.
    /// Used to highlight the matching swatch after the user commits a wheel pick.
    static func nearest(hue: Double, saturation: Double) -> Int? {
        guard saturation > 0.05 else {
            // Near-white → highlight "White" swatch
            return presets.firstIndex { $0.name == "White" }
        }
        var bestIdx: Int? = nil
        var bestDist = Double.infinity
        for (i, s) in presets.enumerated() {
            guard s.name != "White" else { continue }
            // Hue distance on a circle (wraps at 0/1)
            let d = min(abs(s.hue - hue), 1.0 - abs(s.hue - hue))
            let dist = d * d + (s.saturation - saturation) * (s.saturation - saturation) * 0.1
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        // Only highlight if within 15° of a preset
        return bestDist < 0.02 ? bestIdx : nil
    }
}
