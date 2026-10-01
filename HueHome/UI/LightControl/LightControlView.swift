// LightControlView.swift
// ChromaGlow — Light (Luminous).
//
// One lamp on its own stage: an orb in the lamp's colour whose glow is its
// brightness, then power + brightness, colour (wheel, quick colours, My
// Colors) and warmth — each shown only when the lamp can do it.
//
// Contract: the host's callbacks do the optimistic model write and own the
// rollback; this view never writes the binding first. Every control keeps
// its drag state locally and commits ONCE when the finger lifts.

import SwiftUI
import CoreGraphics

// MARK: - LightControlView

struct LightControlView: View {

    @Binding var light: LightDisplayItem
    let onToggle:    (Bool) -> Void   // Bool = desired new on-state
    let onBrightness: (Double) -> Void
    let onColor:      (Double, Double) -> Void      // x, y
    let onColorTemp:  (Int) -> Void                 // mirek
    /// Bridge-native identify flash. Optional so hosts without a bridge
    /// context (previews, demo) simply don't show the button.
    var onIdentify:   (() -> Void)? = nil

    // Local in-progress state (committed on gesture end)
    @State private var liveHue:        Double = 0
    @State private var liveSaturation: Double = 0
    @State private var liveMirek:      Int    = 300
    @State private var selectedSwatch: Int?   = nil  // index into ColorSwatch.presets

    // The brightness slider's drag state — commits ONCE on release; the
    // committed value is what the labels show.
    @State private var displayBrightness: Double = 0
    @State private var brightnessLevel: Double = 50
    @State private var draggingBrightness = false

    /// The colour the lamp is showing (warm white for a lamp that only dims).
    private var lampColor: Color { LuminousLight.color(of: light) }
    private var level: Double { LuminousLight.level(of: light) }

    private var capabilityText: String {
        switch (light.supportsColor, light.supportsColorTemp) {
        case (true, true):  return "Colour and white"
        case (true, false): return "Colour"
        case (false, true): return "Warm to cool white"
        default:            return "Brightness only"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                LuminousScreenTitle(title: light.name,
                                    eyebrow: "Light",
                                    eyebrowSymbol: archetypeIcon(for: light.archetype),
                                    eyebrowTint: light.isOn ? lampColor : LuminousPalette.inkSecondary,
                                    subtitle: light.isOn
                                        ? "On · \(BrightnessDisplay.percent(displayBrightness))% · \(capabilityText)"
                                        : "Off · \(capabilityText)")
                brightnessPanel
                if light.supportsColor {
                    colorSection
                }
                if light.supportsColorTemp {
                    colorTempSection
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background { LuminousAmbience(colors: light.isOn ? [lampColor] : [LuminousPalette.night]) }
        .luminousNavigationChrome()
        .toolbar {
            if let onIdentify {
                ToolbarItem(placement: .topBarTrailing) {
                    // Free bridge signalling: a 3 s flash, self-terminating.
                    Button {
                        HapticManager.shared.light()
                        onIdentify()
                    } label: {
                        Image(systemName: "light.beacon.max")
                    }
                    .accessibilityLabel("Flash to identify")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            syncLocalState()
            displayBrightness = light.brightness
            brightnessLevel = max(1, light.brightness)
        }
        .onChange(of: light.brightness) { _, new in
            displayBrightness = new
            if !draggingBrightness { brightnessLevel = max(1, new) }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Hero
    // ──────────────────────────────────────────────

    /// The lamp on its own stage: its colour, its glow its brightness, the
    /// pool of light it throws. Dark glass when off.
    private var hero: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [LuminousPalette.void, LuminousPalette.night.opacity(0.9), LuminousPalette.void],
                           startPoint: .top, endPoint: .bottom)
            LuminousLampOrb(color: lampColor, level: level, size: 58, showsFloor: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 38)
                .animation(.easeInOut(duration: 0.4), value: level)
            HStack(spacing: 6) {
                LuminousFactBadge(text: light.isOn ? "On · \(BrightnessDisplay.percent(displayBrightness))%" : "Off",
                                  symbol: "power")
                Spacer(minLength: 0)
                LuminousFactBadge(text: capabilityText, symbol: light.supportsColor ? "paintpalette.fill" : "sun.max.fill")
            }
            .padding(12)
        }
        .frame(height: 220)
        .luminousStageFrame()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(light.name), \(light.isOn ? "on at \(BrightnessDisplay.percent(displayBrightness)) percent" : "off")")
    }

    // ──────────────────────────────────────────────
    // MARK: - Power + brightness
    // ──────────────────────────────────────────────

    private var brightnessPanel: some View {
        HStack(spacing: 14) {
            LuminousPowerButton(isOn: light.isOn, tint: lampColor, size: 52,
                                label: "Turn \(light.name) \(light.isOn ? "off" : "on")") {
                HapticManager.shared.medium()
                onToggle(!light.isOn)   // light is @Binding — reads current vm.lights[idx]
            }
            LuminousGlowSlider(title: "Brightness",
                               symbol: "sun.max.fill",
                               value: $brightnessLevel,
                               range: 1...100,
                               colors: [lampColor.opacity(0.5), lampColor],
                               format: { "\(BrightnessDisplay.percent($0))%" },
                               accessibilityName: "\(light.name) brightness",
                               onEditingChanged: { editing in
                                   draggingBrightness = editing
                                   guard !editing else { return }
                                   // One write on release: the host's onBrightness does
                                   // the optimistic model write, the API and rollback.
                                   displayBrightness = brightnessLevel
                                   HapticManager.shared.heavy()
                                   onBrightness(brightnessLevel)
                               })
        }
        .padding(14)
        .luminousPanel(glow: light.isOn ? lampColor : nil, glowStrength: light.isOn ? 0.3 + 0.7 * level : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: light.isOn)
    }

    // ──────────────────────────────────────────────
    // MARK: - Colour
    // ──────────────────────────────────────────────

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: "Colour", subtitle: "Drag across the wheel, or pick a colour below.")
            VStack(spacing: 18) {
                ColorWheelView(
                    hue: $liveHue,
                    saturation: $liveSaturation
                ) { h, s in
                    // Commit: convert HSB → xy and call the host. The host's
                    // onColor does the optimistic model write (and owns the
                    // rollback) — writing the binding first made the rollback
                    // "restore" the new value.
                    let (x, y) = HueColorUtils.xyFrom(hue: h, saturation: s, brightness: 1)
                    selectedSwatch = ColorSwatch.nearest(hue: h, saturation: s)
                    HapticManager.shared.heavy()
                    onColor(x, y)
                }
                .frame(width: 236, height: 236)
                .frame(maxWidth: .infinity)

                colorSwatchGrid
                    .padding(.horizontal, 16)

                Rectangle().fill(LuminousPalette.hairline).frame(height: 1)
                    .padding(.horizontal, 16)

                myColorsRow
            }
            .padding(.vertical, 18)
            .luminousGlass()
        }
    }

    /// Saved palette: ＋ captures the light's current look (colour +
    /// brightness); tapping a swatch applies it with the light's capability
    /// fallback.
    private var myColorsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: "My Colors")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            onColor(x, y)
            commitSavedBrightness(brightness)
        case .colorTemp(let mirek, let brightness):
            liveMirek = mirek
            onColorTemp(mirek)
            commitSavedBrightness(brightness)
        case .brightnessOnly(let brightness):
            commitSavedBrightness(brightness)
        }
        HapticManager.shared.heavy()
    }

    private func commitSavedBrightness(_ brightness: Double) {
        displayBrightness = brightness
        brightnessLevel = max(1, brightness)
        onBrightness(brightness)   // host writes the model (and rolls back)
    }

    /// The twelve quick colours as glowing beads, two rows of six.
    private var colorSwatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
            ForEach(Array(ColorSwatch.presets.enumerated()), id: \.offset) { i, swatch in
                let selected = selectedSwatch == i
                Button {
                    liveHue        = swatch.hue
                    liveSaturation = swatch.saturation
                    selectedSwatch = i
                    let (x, y) = HueColorUtils.xyFrom(
                        hue: swatch.hue, saturation: swatch.saturation, brightness: 1
                    )
                    HapticManager.shared.heavy()
                    onColor(x, y)
                } label: {
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.75), swatch.color],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 20))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 2.5 : 1))
                        .shadow(color: swatch.color.opacity(selected ? 0.9 : 0.55), radius: selected ? 10 : 6)
                        .scaleEffect(selected ? 1.1 : 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(LuminousPressStyle(scale: 0.88))
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Warmth
    // ──────────────────────────────────────────────

    private var colorTempSection: some View {
        // liveMirek is updated only on commit — not during a drag.
        let kelvin = HueColorUtils.kelvin(from: liveMirek)
        return VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: "Warmth", subtitle: "From candlelight to daylight.") {
                Text("\(kelvin)K")
                    .font(LuminousType.value)
                    .foregroundStyle(LuminousPalette.ink.opacity(0.8))
                    .contentTransition(.numericText())
            }
            VStack(spacing: 14) {
                ColorTempSlider(
                    currentMirek: liveMirek,
                    mirekMin: light.mirekMin,
                    mirekMax: light.mirekMax
                ) { mirek in
                    liveMirek = mirek                // update the label once on release
                    HapticManager.shared.heavy()
                    // onColorTemp does the optimistic model write + rollback.
                    onColorTemp(mirek)
                }
                .padding(.horizontal, 16)

                // White-only lights have no colour section — give them their
                // own My Colors row so warm/cool whites are saveable too.
                if !light.supportsColor {
                    Rectangle().fill(LuminousPalette.hairline).frame(height: 1)
                        .padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 8) {
                        LuminousEyebrow(text: "My Colors")
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
            .padding(.vertical, 18)
            .luminousGlass()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

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
                // ── A soft glow of the picked colour behind the wheel ──
                Circle()
                    .fill(Color(hue: hue, saturation: max(0.35, saturation), brightness: 1).opacity(0.28))
                    .frame(width: radius * 2 + 24, height: radius * 2 + 24)
                    .blur(radius: 18)
                    .position(center)

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

                // ── Glass rim ─────────────────────────
                Circle()
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                // ── Thumb: a glowing bead of the picked colour ─
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: isDragging ? 32 : 26, height: isDragging ? 32 : 26)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: Color(hue: hue, saturation: max(0.4, saturation), brightness: 1).opacity(0.9),
                            radius: isDragging ? 14 : 8)
                    .shadow(color: .black.opacity(0.35), radius: 3)
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
                let thumb: CGFloat = isDragging ? 32 : 26
                let thumbX = sliderValue * geo.size.width
                let thumbColor = HueColorUtils.color(fromMirek: localMirek)
                ZStack(alignment: .leading) {
                    LinearGradient(gradient: HueColorUtils.colorTempGradient,
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        .frame(height: 10)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: thumbColor.opacity(0.45), radius: isDragging ? 12 : 7)
                    Circle()
                        .fill(.white)
                        .frame(width: thumb, height: thumb)
                        .overlay(Circle().fill(thumbColor.opacity(0.55)).padding(7))
                        .shadow(color: thumbColor.opacity(0.9), radius: isDragging ? 14 : 8)
                        .offset(x: max(0, min(thumbX - thumb / 2, geo.size.width - thumb)))
                        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isDragging)
                }
                .frame(height: 32)
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
            .frame(height: 32)

            HStack {
                Label("Warm", systemImage: "flame.fill")
                Spacer()
                Label("Cool", systemImage: "sun.max.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(LuminousPalette.inkSecondary)
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
        // VoiceOver: one adjustable element, each step commits once.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warmth")
        .accessibilityValue("\(HueColorUtils.kelvin(from: localMirek)) kelvin")
        .accessibilityAdjustableAction { direction in
            let step = 0.1
            switch direction {
            case .increment: sliderValue = min(1, sliderValue + step)
            case .decrement: sliderValue = max(0, sliderValue - step)
            @unknown default: return
            }
            localMirek = HueColorUtils.mirek(fromSlider: sliderValue, min: mirekMin, max: mirekMax)
            onCommit(localMirek)
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
