// CompositionEditorPanel.swift
// CastChroma — Composer editor (extracted from StudioView in Round 4, R4-1).
//
// The four-layer live mixer for the running composition: Palette / Motion /
// Envelope / React tabs, the beat quick-toggle, and the dynamic-scene export.
// Pure move — every member is byte-identical to its StudioView original;
// only access levels and parameter plumbing changed.
//
// Ownership:
//   - Panel owns transient editor state (hue-pad drag, prompts).
//   - The active layer tab is PER-TARGET session working memory
//     (`TargetWorkingState.activeCompositionTab`, spec §14.4 / plan §24): two
//     rooms running compositions no longer share one tab, and a stopped
//     target's tab dies with it. The host hands the binding in.
//   - StudioView keeps @State for activeHarmonyRule / editingSwatch because the
//     harmony-restore onChange chain runs at StudioView scope even while the
//     customization region is closed.
//
// One surface (Guard 13): each layer is ONE StageCard holding its essential
// controls and, directly below them in the same column, its supporting tier
// (`ComposerSupportingControls`). There is no "Advanced" card and no
// `.id(tab)` split — the `switch` gives each layer its own structural
// identity and the whole card lives and dies as one.

import SwiftUI
import CoreGraphics

// MARK: - Layer Tabs

enum CompositionLayerTab: String, CaseIterable, Identifiable, Hashable {
    case palette
    case motion
    case envelope
    case reaction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .palette: return "Palette"
        case .motion: return "Motion"
        case .envelope: return "Brightness"
        case .reaction: return "React"
        }
    }

    var symbolName: String {
        switch self {
        case .palette: return "paintpalette.fill"
        case .motion: return "wind"
        case .envelope: return "chart.xyaxis.line"
        case .reaction: return "mic.fill"
        }
    }
}

struct SwatchEditItem: Identifiable { let id: Int }

// MARK: - CompositionEditorPanel

struct CompositionEditorPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let vm: StudioViewModel
    /// Handed in by the host rather than read from the environment, so the
    /// panel's body is evaluable outside a SwiftUI graph — the structural
    /// migration tests walk the evaluated tree (`ComposerConvergenceTests`).
    let orchestrator: UnifiedOrchestrator
    @Binding var activeCompositionTab: CompositionLayerTab
    @Binding var activeHarmonyRule: HarmonyRule
    @Binding var editingSwatch: SwatchEditItem?

    var body: some View {
        compositionMixerBody
    }

    private var isCompactStudio: Bool {
        UIScreen.main.bounds.height <= 700 || dynamicTypeSize.isAccessibilitySize
    }

    private var compositionMixerBody: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            HStack(alignment: .top) {
                compositionSectionHeader("Layers", subtitle: "Choose a layer to edit live.")
                Spacer()
                beatQuickToggle
            }
            .padding(.bottom, -2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CompositionLayerTab.allCases) { tab in
                        let selected = activeCompositionTab == tab
                        Button {
                            activeCompositionTab = tab
                            HapticManager.shared.selection()
                        } label: {
                            Label(tab.title, systemImage: tab.symbolName)
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(selected ? HuePalette.amber : .white.opacity(0.78))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selected ? HuePalette.amber.opacity(0.18) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(selected ? HuePalette.amber.opacity(0.55) : Color.white.opacity(0.10), lineWidth: 1)
                                )
                                .frame(minHeight: HueHit.min)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)

            // Each case is a distinct view, so the switch alone gives every
            // layer its own structural identity — the transition fires on the
            // swap without an `.id(tab)` that would ALSO have torn down a
            // knob's in-flight exact-entry draft on every programmatic tab
            // change (the beat quick-toggle jumps here).
            // ONE instant of capability truth for the whole page (S3-4):
            // built here, handed to every layer, so no control answers
            // against a different snapshot than its neighbour.
            let availability = ComposerAvailabilityContext(vm: vm)
            Group {
                switch activeCompositionTab {
                case .palette: compositionPaletteControls(availability)
                case .motion: compositionMotionControls(availability)
                case .envelope: compositionEnvelopeControls(availability)
                case .reaction: compositionReactionControls(availability)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .animation(HueAnimation.fast, value: activeCompositionTab)
        }
    }

    /// The supporting tier for the active layer, rendered at the bottom of
    /// that layer's card. A hairline — not a caption — marks where the
    /// essentials end; there is nothing to tap and nothing to open.
    @ViewBuilder
    private func supportingTier(_ tab: CompositionLayerTab,
                                _ availability: ComposerAvailabilityContext) -> some View {
        Rectangle()
            .fill(StagePalette.line)
            .frame(height: 1)
            .padding(.top, 2)
        ComposerSupportingControls(vm: vm, orchestrator: orchestrator,
                                   availability: availability, tab: tab)
    }

    /// One-tap beat enable for the whole composition: flips the Reaction
    /// source to .beat and jumps to the Reaction tab (the auto-anchor then
    /// scrolls the beat controls into view). Tapping again turns it off.
    private var beatQuickToggle: some View {
        let source = vm.activeCompositionBox?.reaction.source ?? .none
        let isBeatOn = source == .beat || source == .onset || source == .tapTempo
        return Button {
            withAnimation(HueAnimation.fast) {
                if isBeatOn {
                    vm.activeCompositionBox?.reaction.source = .none
                } else {
                    vm.activeCompositionBox?.reaction.source = .beat
                    activeCompositionTab = .reaction
                }
            }
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isBeatOn ? "Beat On" : "Beat")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(isBeatOn ? Color.black.opacity(0.85) : HuePalette.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isBeatOn ? HuePalette.amber : HuePalette.amber.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBeatOn ? "Disable beat reaction" : "Enable beat reaction")
    }

    private func compositionSectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(HueFont.stageTag)
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reactionTargetLabel(_ target: ReactionConfig.Target) -> String {
        switch target {
        case .brightness: return "Brightness"
        case .color: return "Color"
        case .speed: return "Speed"
        }
    }

    private func reactionTargetToggleBinding(_ target: ReactionConfig.Target,
                                             interactive: Bool) -> Binding<Bool> {
        Binding(
            get: { vm.activeCompositionBox?.reaction.targets.contains(target) ?? false },
            set: { on in
                guard interactive, let box = vm.activeCompositionBox else { return }
                var targets = box.reaction.targets
                if on {
                    if !targets.contains(target) { targets.append(target) }
                } else {
                    targets.removeAll { $0 == target }
                }
                if targets.isEmpty { targets = [.brightness] }
                box.reaction.targets = targets
            }
        )
    }

    /// Harmony chips belong to solid/gradient mode. Whether the target's
    /// lights can render them is the funnel's answer (`harmony`), applied by
    /// the gate around the row — a colourless room sees the row DISABLED
    /// under "NO COLOR LIGHTS HERE", an unread room under CHECKING; neither
    /// silently loses it.
    private var showHarmonyControls: Bool {
        let mode = vm.activeCompositionBox?.palette.mode ?? .gradient
        return mode == .solid || mode == .gradient
    }

    /// Rules exposed in the chip row — excludes 4-color rules until color4 is added.
    private var filteredHarmonyRules: [HarmonyRule] {
        [.none, .complementary, .triadic, .analogous, .splitComplementary, .monochromatic]
    }

    private func compositionPaletteControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "paintpalette.fill", title: "Color", subtitle: "Palette every light reads before motion and envelope.") {
            VStack(spacing: HueSpacing.sm) {

            let mode = availability.resolve("mode")
            ComposerControlGate(label: "Mode", resolution: mode) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode")
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: PaletteConfig.Mode.allCases.map { mode in
                        ChipPickerRow<PaletteConfig.Mode>.Item(
                            value: mode, label: mode.rawValue.capitalized)
                    },
                    selection: composerGuarded(ComposerControlAvailability.isInteractive(mode), Binding(
                        get: { vm.activeCompositionBox?.palette.mode ?? .gradient },
                        set: { newMode in
                            vm.activeCompositionBox?.palette.mode = newMode
                            // Auto-dismiss harmony when switching to a mode that ignores color fields
                            if newMode != .solid && newMode != .gradient && activeHarmonyRule != .none {
                                activeHarmonyRule = .none
                            }
                        }
                    ))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            if (vm.activeCompositionBox?.palette.mode ?? .gradient) == .temperature {
                // Temperature mode ignores color1/saturation — the pad was a
                // fully dead control surface here. Warmth is what the engine
                // reads (spectrum approximation live, real mirek one-shot).
                //
                // The range is the TARGET's intersected mirek range (row 58):
                // on a narrower fixture the control travels exactly as far as
                // the lights can go. With no readable range the funnel answers
                // CHECKING and the control is disabled — the fallback span is
                // only somewhere for the stored value to sit while disabled.
                let temperature = availability.resolve("temperature")
                ComposerControlGate(label: "Warmth", resolution: temperature) {
                    StageSlider(
                        title: "Warmth",
                        value: composerGuarded(ComposerControlAvailability.isInteractive(temperature), Binding(
                            get: { Double(vm.activeCompositionBox?.palette.temperature ?? 366) },
                            set: { vm.activeCompositionBox?.palette.temperature = Int($0.rounded()) }
                        )),
                        range: availability.warmthRange ?? ComposerControlAvailability.fallbackWarmthRange,
                        format: StudioParamFormat.kelvin
                    )
                }
            } else {
                let colorPad = availability.resolve("colorPad")
                ComposerControlGate(label: "Color", resolution: colorPad, isColor: true) {
                    hueSaturationPad(interactive: ComposerControlAvailability.isInteractive(colorPad))
                }
            }

            harmonyChipRow(availability)

            supportingTier(.palette, availability)
        }
            }
    }

    // ──────────────────────────────────────────────
    // MARK: - Harmony Chip Row
    // ──────────────────────────────────────────────

    @ViewBuilder
    private func harmonyChipRow(_ availability: ComposerAvailabilityContext) -> some View {
        if showHarmonyControls {
            let harmony = availability.resolve("harmony")
            let interactive = ComposerControlAvailability.isInteractive(harmony)
            ComposerControlGate(label: "Harmony", resolution: harmony, isColor: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("HARMONY")
                    .font(HueFont.stageTag)
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(0.6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filteredHarmonyRules) { rule in
                            harmonyChipButton(rule, interactive: interactive)
                        }
                    }
                }

                if activeHarmonyRule != .none {
                    harmonySwatchPreview(interactive: interactive)
                        .popover(item: $editingSwatch) { item in
                            swatchEditPopover(index: item.id, interactive: interactive)
                        }

                    // Hint for static motion
                    if vm.activeCompositionBox?.motion.pattern == .static {
                        Text("Try Cascade or Wave to spread harmony across lights")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.40))
                            .padding(.top, 2)
                    }
                }
            }
            }
        }
    }

    private func harmonyChipButton(_ rule: HarmonyRule, interactive: Bool) -> some View {
        let isSelected = activeHarmonyRule == rule
        return Button {
            guard interactive else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                activeHarmonyRule = rule
            }
            HapticManager.shared.medium()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: rule.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(rule.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? HuePalette.amber : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : .white.opacity(0.08), lineWidth: 1)
            )
            .frame(minHeight: HueHit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(harmonyAccessibilityName(for: rule))
    }

    private func harmonyAccessibilityName(for rule: HarmonyRule) -> String {
        switch rule {
        case .none: return "No harmony"
        case .complementary: return "Complementary"
        case .triadic: return "Triadic"
        case .analogous: return "Analogous"
        case .splitComplementary: return "Split Complementary"
        case .monochromatic: return "Monochromatic"
        case .tetradic: return "Tetradic"
        case .doubleComp: return "Double Complementary"
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Harmony Preview Swatches
    // ──────────────────────────────────────────────

    private func harmonySwatchPreview(interactive: Bool) -> some View {
        // Spacing 0: each swatch sits centered in its own 44pt hit frame, so
        // the hit boxes tile edge-to-edge without overlapping.
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                let color = harmonySwatchColor(at: index)
                let isEditing = editingSwatch?.id == index
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.white.opacity(isEditing ? 0.9 : 0.5), lineWidth: isEditing ? 2.5 : 1.5))
                    .shadow(color: color.opacity(isEditing ? 0.7 : 0.4), radius: isEditing ? 8 : 4)
                    .frame(width: HueHit.min, height: HueHit.min)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A tap gesture is not a Control: `.disabled` does not
                        // close it, so the funnel's verdict is applied here.
                        guard interactive else { return }
                        editingSwatch = (editingSwatch?.id == index) ? nil : SwatchEditItem(id: index)
                        HapticManager.shared.selection()
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isEditing)
            }
            Spacer()
            Text("Tap to fine-tune")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.30))
        }
    }

    private func harmonySwatchColor(at index: Int) -> Color {
        guard let box = vm.activeCompositionBox else { return .gray }
        let c: CodableColor
        switch index {
        case 0: c = box.palette.color1
        case 1: c = box.palette.color2
        case 2: c = box.palette.color3 ?? box.palette.color2
        default: c = box.palette.color1
        }
        return HueColorUtils.color(fromX: c.x, y: c.y, brightness: 100)
    }

    private func swatchEditPopover(index: Int, interactive: Bool) -> some View {
        VStack(spacing: 12) {
            Text("Color \(index + 1)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            ColorWheelView(
                hue: composerGuarded(interactive, swatchHueBinding(index)),
                saturation: composerGuarded(interactive, swatchSatBinding(index))
            ) { h, s in
                guard interactive else { return }
                commitSwatchEdit(index: index, hue: h, saturation: s)
            }
            .frame(width: 180, height: 180)
        }
        .padding(16)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        .preferredColorScheme(.dark)
        .presentationCompactAdaptation(.popover)
    }

    private func swatchHueBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let box = vm.activeCompositionBox else { return 0 }
                let c: CodableColor
                switch index {
                case 0: c = box.palette.color1
                case 1: c = box.palette.color2
                case 2: c = box.palette.color3 ?? box.palette.color2
                default: c = box.palette.color1
                }
                return HueColorUtils.hsb(fromX: c.x, y: c.y, brightness: 100).h
            },
            set: { newHue in
                let sat = swatchSatBinding(index).wrappedValue
                commitSwatchEdit(index: index, hue: newHue, saturation: sat)
            }
        )
    }

    private func swatchSatBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let box = vm.activeCompositionBox else { return 1 }
                let c: CodableColor
                switch index {
                case 0: c = box.palette.color1
                case 1: c = box.palette.color2
                case 2: c = box.palette.color3 ?? box.palette.color2
                default: c = box.palette.color1
                }
                return HueColorUtils.hsb(fromX: c.x, y: c.y, brightness: 100).s
            },
            set: { newSat in
                let hue = swatchHueBinding(index).wrappedValue
                commitSwatchEdit(index: index, hue: hue, saturation: newSat)
            }
        )
    }

    private func commitSwatchEdit(index: Int, hue: Double, saturation: Double) {
        guard let box = vm.activeCompositionBox else { return }
        let xy = HueColorUtils.xyFrom(hue: hue, saturation: saturation, brightness: 1.0)
        let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: vm.activeCompositionGamut)
        let color = CodableColor(x: clamped.x, y: clamped.y)
        switch index {
        case 0: box.palette.color1 = color
        case 1: box.palette.color2 = color
        case 2: box.palette.color3 = color
        default: break
        }
        box.triggerRESTBurst()
    }

    /// The pad itself is the shared StageKit `HueSaturationPad`; what stays
    /// here is what makes it the COMPOSER's pad — writing the live palette
    /// (harmony-aware) and pacing the REST burst per drag sample.
    private func hueSaturationPad(interactive: Bool) -> some View {
        let canonicalHSB: (h: Double, s: Double) = {
            guard let c = vm.activeCompositionBox?.palette.color1 else { return (0.0, 1.0) }
            let clampedXY = HueColorUtils.clampXYToGamut(
                x: c.x,
                y: c.y,
                gamut: vm.activeCompositionGamut
            )
            let hsb = HueColorUtils.hsb(fromX: clampedXY.x, y: clampedXY.y, brightness: 100)
            return (h: hsb.h, s: hsb.s)
        }()

        return HueSaturationPad(
            hue: canonicalHSB.h,
            saturation: canonicalHSB.s,
            gamut: vm.activeCompositionGamut,
            height: isCompactStudio ? 118 : 156,
            onChanged: { hue, sat, xy in
                // The pad's drag is a raw gesture that `.disabled` does not
                // close: the funnel's verdict is the floor here (same rule as
                // StageColorEditor).
                guard interactive else { return }
                // Per-sample: keep the REST mailbox in burst pacing while the
                // finger moves (repeated calls extend the burst window).
                vm.activeCompositionBox?.triggerRESTBurst()
                if activeHarmonyRule != .none {
                    let paletteColors = HarmonyEngine.palette(
                        rule: activeHarmonyRule,
                        rootHue: hue,
                        saturation: sat,
                        brightness: 1.0,
                        count: 3
                    )
                    let gamut = vm.activeCompositionGamut
                    vm.activeCompositionBox?.palette.color1 = HueColorUtils.codableColor(from: paletteColors[0], gamut: gamut)
                    vm.activeCompositionBox?.palette.color2 = HueColorUtils.codableColor(from: paletteColors[1], gamut: gamut)
                    if paletteColors.count >= 3 {
                        vm.activeCompositionBox?.palette.color3 = HueColorUtils.codableColor(from: paletteColors[2], gamut: gamut)
                    } else {
                        vm.activeCompositionBox?.palette.color3 = nil
                    }
                } else {
                    vm.activeCompositionBox?.palette.color1 = CodableColor(x: xy.x, y: xy.y)
                }
                vm.activeCompositionBox?.palette.saturation = sat * 100
            },
            onDragStateChanged: { dragging in
                guard interactive else { return }
                vm.activeCompositionBox?.isColorPadInteracting = dragging
                if !dragging { vm.activeCompositionBox?.triggerRESTBurst() }
            }
        )
    }

    /// One icon per motion pattern — the pill's visual signature.
    private static let patternIcons: [String: String] = [
        "static":       "pause.fill",
        "cascade":      "arrow.right",
        "wave":         "water.waves",
        "scatter":      "shuffle",
        "bounce":       "arrow.left.and.right",
        "chase":        "forward.fill",
        "comet":        "paperplane.fill",
        "pulse_center": "target",
        "spiral":       "hurricane",
        "twinkle":      "sparkles",
    ]

    private static let sourceLabels: [String: String] = [
        "none": "None", "mic_amplitude": "Mic", "mic_bass": "Bass",
        "mic_mid": "Mid", "mic_treble": "Treble", "tap_tempo": "Tap",
        "beat": "Beat", "onset": "Hits",
    ]

    private static let sourceIcons: [String: String] = [
        "none":          "slash.circle",
        "mic_amplitude": "mic.fill",
        "mic_bass":      "speaker.wave.3.fill",
        "mic_mid":       "speaker.wave.2.fill",
        "mic_treble":    "speaker.wave.1.fill",
        "tap_tempo":     "hand.tap",
        "beat":          "metronome.fill",
        "onset":         "bolt.fill",
    ]

    private func compositionMotionControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "wind", title: "Motion", subtitle: "How color travels across lights over time.") {
            VStack(spacing: HueSpacing.sm) {

            PatternStripView(
                pattern: vm.activeCompositionBox?.motion.pattern ?? .cascade,
                animated: vm.currentRoomEffect != nil
            )

            // One-tap pattern pills: every pattern visible at once (was a
            // 2-tap menu). Icons give each motion a recognizable signature.
            let patternRes = availability.resolve("pattern")
            ComposerControlGate(label: "Pattern", resolution: patternRes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pattern")
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: MotionConfig.Pattern.allCases.map { pattern in
                        ChipPickerRow<MotionConfig.Pattern>.Item(
                            value: pattern,
                            label: pattern.rawValue
                                .replacingOccurrences(of: "_", with: " ").capitalized,
                            icon: Self.patternIcons[pattern.rawValue])
                    },
                    selection: composerGuarded(ComposerControlAvailability.isInteractive(patternRes), Binding(
                        get: { vm.activeCompositionBox?.motion.pattern ?? .cascade },
                        set: { vm.activeCompositionBox?.motion.pattern = $0 }
                    ))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            // .static ignores speed/forward/spread/offset/mirror entirely —
            // showing them would be dead controls (the engine returns a
            // fixed phase). Direction and the rest are the supporting tier.
            let pattern = vm.activeCompositionBox?.motion.pattern ?? .cascade
            if pattern != .static {
                let speed = availability.resolve("speed")
                ComposerControlGate(label: "Speed", resolution: speed) {
                    StageSlider(
                        title: "Speed",
                        value: composerGuarded(ComposerControlAvailability.isInteractive(speed), Binding(
                            get: { vm.activeCompositionBox?.motion.speed ?? 40 },
                            set: { vm.activeCompositionBox?.motion.speed = $0 }
                        )),
                        range: 0...100
                    )
                }

                if ComposerControlCatalog.isSpatialPattern(pattern) {
                    let forward = availability.resolve("forward")
                    ComposerControlGate(label: "Forward", resolution: forward) {
                        StageToggleRow(
                            title: "Forward",
                            isOn: composerGuarded(ComposerControlAvailability.isInteractive(forward), Binding(
                                get: { vm.activeCompositionBox?.motion.forward ?? true },
                                set: { vm.activeCompositionBox?.motion.forward = $0 }
                            ))
                        )
                    }
                }
            } else {
                Text("Static holds every light on its palette color — pick a moving pattern to unlock speed and direction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.40))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if pattern != .static {
                supportingTier(.motion, availability)
            }
        }
            }
    }

    private func compositionEnvelopeControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "waveform.path.ecg", title: "Brightness Shape", subtitle: "How brightness moves over time.") {
            VStack(spacing: HueSpacing.sm) {

            // The configured curve, live — what these controls actually do.
            EnvelopeStripView(envelope: vm.activeCompositionBox?.envelope ?? EnvelopeConfig())

            let shapeRes = availability.resolve("shape")
            ComposerControlGate(label: "Shape", resolution: shapeRes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shape")
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: EnvelopeConfig.Shape.allCases.map { shape in
                        ChipPickerRow<EnvelopeConfig.Shape>.Item(
                            value: shape, label: shape.rawValue.capitalized,
                            curveSamples: EnvelopeStripMath.thumbnail(for: shape))
                    },
                    selection: composerGuarded(ComposerControlAvailability.isInteractive(shapeRes), Binding(
                        get: { vm.activeCompositionBox?.envelope.shape ?? .breathe },
                        set: { vm.activeCompositionBox?.envelope.shape = $0 }
                    ))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            // .steady returns max brightness only — bpm/depth are no-ops.
            if (vm.activeCompositionBox?.envelope.shape ?? .breathe) != .steady {
                let bpm = availability.resolve("bpm")
                ComposerControlGate(label: "BPM", resolution: bpm) {
                    StageSlider(
                        title: "BPM",
                        value: composerGuarded(ComposerControlAvailability.isInteractive(bpm), Binding(
                            get: { vm.activeCompositionBox?.envelope.bpm ?? 60 },
                            set: { vm.activeCompositionBox?.envelope.bpm = $0 }
                        )),
                        range: 20...240
                    )
                }

                let depth = availability.resolve("depth")
                ComposerControlGate(label: "Depth", resolution: depth) {
                    StageSlider(
                        title: "Depth",
                        value: composerGuarded(ComposerControlAvailability.isInteractive(depth), Binding(
                            get: { vm.activeCompositionBox?.envelope.depth ?? 50 },
                            set: { vm.activeCompositionBox?.envelope.depth = $0 }
                        )),
                        range: 0...100
                    )
                }
            }

            supportingTier(.envelope, availability)
        }
            }
    }

    private func compositionReactionControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "bolt.fill", title: "React", subtitle: "Audio and responsiveness layered on top.") {
            VStack(spacing: HueSpacing.sm) {

            let sourceRes = availability.resolve("source")
            ComposerControlGate(label: "Source", resolution: sourceRes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: ReactionConfig.Source.allCases.map { source in
                        ChipPickerRow<ReactionConfig.Source>.Item(
                            value: source,
                            label: Self.sourceLabels[source.rawValue]
                                ?? source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                            icon: Self.sourceIcons[source.rawValue])
                    },
                    selection: composerGuarded(ComposerControlAvailability.isInteractive(sourceRes), Binding(
                        get: { vm.activeCompositionBox?.reaction.source ?? .none },
                        set: { vm.activeCompositionBox?.reaction.source = $0 }
                    ))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            if (vm.activeCompositionBox?.reaction.source ?? .none) != .none {
                let targetsRes = availability.resolve("targets")
                // The `.color` target modulates a colour no light here may
                // render — it carries its own colour requirement.
                let targetColorRes = availability.resolve("targetColor")
                ComposerControlGate(label: "Targets", resolution: targetsRes) {
                VStack(alignment: .leading, spacing: 8) {
                    compositionSectionHeader("Targets", subtitle: "Which outputs the reaction modulates.")
                    ForEach(ReactionConfig.Target.allCases, id: \.self) { target in
                        let res = target == .color ? targetColorRes : targetsRes
                        let interactive = ComposerControlAvailability.isInteractive(res)
                        Toggle(reactionTargetLabel(target),
                               isOn: reactionTargetToggleBinding(target, interactive: interactive))
                            .tint(HuePalette.amber)
                            .disabled(!interactive)
                            .opacity(ComposerControlAvailability.opacity(res))
                    }
                    if let note = ComposerControlAvailability.note(for: targetColorRes, isColor: false) {
                        Text(note)
                            .font(HueFont.stageTag)
                            .foregroundStyle(HuePalette.amber.opacity(0.65))
                            .tracking(0.6)
                            .accessibilityLabel("Color target: \(note)")
                    }
                }
                }
            }

            reactionBeatControls
                .id("reactionBeatControls")   // ScrollViewReader auto-anchor target

            // Sensitivity shapes the MIC drive only — beat/onset sources use
            // punchDecay (in the beat panel) for their feel.
            if ComposerControlCatalog.isMicSource(vm.activeCompositionBox?.reaction.source ?? .none) {
                // Live level meter (polls the analysis engine, never starts
                // the mic) with the noise-gate threshold ticked on the bar.
                MicLevelMeterView(threshold: vm.activeCompositionBox?.reaction.threshold)
                let sensitivity = availability.resolve("sensitivity")
                ComposerControlGate(label: "Sensitivity", resolution: sensitivity) {
                    StageSlider(
                        title: "Sensitivity",
                        value: composerGuarded(ComposerControlAvailability.isInteractive(sensitivity), Binding(
                            get: { vm.activeCompositionBox?.reaction.sensitivity ?? 70 },
                            set: { vm.activeCompositionBox?.reaction.sensitivity = $0 }
                        )),
                        range: 0...100
                    )
                }
            }

            if (vm.activeCompositionBox?.reaction.source ?? .none) != .none {
                supportingTier(.reaction, availability)
            }
        }
            }
    }

    /// Beat-clock section for the beat/onset/tap-tempo reaction sources —
    /// the shared BeatPanelView with Composer capabilities plus the reaction
    /// controls (punch decay, quantized color step, motion lock). One beat
    /// panel app-wide since R4-5.
    @ViewBuilder
    private var reactionBeatControls: some View {
        let source = vm.activeCompositionBox?.reaction.source ?? .none
        if source == .beat || source == .onset || source == .tapTempo {
            BeatPanelView(
                capabilities: .composer,
                reaction: Binding(
                    get: { vm.activeCompositionBox?.reaction ?? ReactionConfig() },
                    set: { vm.activeCompositionBox?.reaction = $0 }
                )
            )
        }
    }
}
