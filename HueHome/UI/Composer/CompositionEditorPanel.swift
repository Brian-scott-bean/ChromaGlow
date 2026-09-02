// CompositionEditorPanel.swift
// CastChroma — Composer editor (extracted from StudioView in Round 4, R4-1;
// converged onto the Studio instrument language in Slice 3).
//
// The four-layer live mixer for the running composition: Palette / Motion /
// Envelope / React layers, the beat quick-toggle, and the dynamic-scene
// export. Composer keeps its full domain model (spec §20) — every control
// reads and writes one typed field of the live `CompositionParamBox` — and
// borrows the shared instruments by MEANING (spec §9): knobs for rates and
// character, faders for levels, pads/chips for discrete choices, the CT-aware
// warmth knob, the inline pad for colour.
//
// Ownership:
//   - Panel owns transient editor state (hue-pad drag, prompts).
//   - The active layer tab is PER-TARGET session working memory
//     (`TargetWorkingState.activeCompositionTab`, spec §14.4 / plan §24): two
//     rooms running compositions no longer share one tab, and a stopped
//     target's tab dies with it. The host hands the binding in.
//   - StudioView keeps @State for activeHarmonyRule because the harmony-
//     restore onChange chain runs at StudioView scope even while the
//     customization region is closed.
//   - Per-swatch colour editing is INLINE (`ComposerHarmonySwatches`, S3-3):
//     the shared StageColorEditor expands in place under the swatch row, its
//     expansion in per-target session memory — no popover, no Done.
//
// One surface (Guard 13): each layer is ONE StageCard holding its essential
// controls and, directly below them in the same column, its supporting tier
// (`ComposerSupportingControls`). There is no "Advanced" card and no
// `.id(tab)` split — the `switch` gives each layer its own structural
// identity and the whole card lives and dies as one.
//
// Truth and fencing: ONE `ComposerAvailabilityContext` per render carries the
// capability snapshot (S3-4) and the edit session (S3-5) for every control on
// the page; every write goes through `commitComposerEdit`, never through a
// box re-resolved from `selectedRoom`.

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

// MARK: - CompositionEditorPanel

struct CompositionEditorPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let vm: StudioViewModel
    /// Handed in by the host rather than read from the environment, so the
    /// panel's body is evaluable outside a SwiftUI graph — the structural
    /// migration tests walk the evaluated tree (`ComposerConvergenceTests`).
    let orchestrator: UnifiedOrchestrator
    @Binding var activeCompositionTab: CompositionLayerTab
    @Binding var activeHarmonyRule: HarmonyRule
    /// Resign the keyboard BEFORE a programmatic layer change, so a typed
    /// exact-entry draft commits (or drops) deterministically instead of
    /// dying inside the torn-down subtree. Owned by the host.
    var onDismissKeyboard: () -> Void = {}

    var body: some View {
        compositionMixerBody
    }

    private var isCompactStudio: Bool {
        UIScreen.main.bounds.height <= 700 || dynamicTypeSize.isAccessibilitySize
    }

    private var compositionMixerBody: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            // ONE instant of capability truth and ONE edit session for the
            // whole page (S3-4 / S3-5): built here, handed to every layer, so
            // no control answers against a different snapshot than its
            // neighbour and no write re-resolves the box.
            let availability = ComposerAvailabilityContext(vm: vm)

            HStack(alignment: .top) {
                compositionSectionHeader("Layers", subtitle: "Choose a layer to edit live.")
                Spacer()
                beatQuickToggle(availability)
            }
            .padding(.bottom, -2)

            // The compact horizontal domain switcher (spec §12.2) — moving
            // across domains of the same instrument, never navigation.
            StageSteppedEncoder(
                title: "",
                items: CompositionLayerTab.allCases.map {
                    ChipPickerRow<CompositionLayerTab>.Item(value: $0, label: $0.title, icon: $0.symbolName)
                },
                selection: Binding(
                    get: { activeCompositionTab },
                    set: { tab in
                        guard tab != activeCompositionTab else { return }
                        onDismissKeyboard()
                        activeCompositionTab = tab
                    }
                ),
                prominence: .chips)

            // Each case is a distinct view, so the switch alone gives every
            // layer its own structural identity — the transition fires on the
            // swap without an `.id(tab)` that would ALSO have torn down a
            // knob's in-flight exact-entry draft on every programmatic tab
            // change (the beat quick-toggle jumps here).
            Group {
                switch activeCompositionTab {
                case .palette: compositionPaletteControls(availability)
                case .motion: compositionMotionControls(availability)
                case .envelope: compositionEnvelopeControls(availability)
                case .reaction: compositionReactionControls(availability)
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            .animation(reduceMotion ? nil : HueAnimation.fast, value: activeCompositionTab)
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
    /// source to .beat and jumps to the Reaction layer (the auto-anchor then
    /// scrolls the beat controls into view). Tapping again turns it off. A
    /// header affordance, not a control row — it lives beside the section
    /// caption, so it keeps its compact pill.
    private func beatQuickToggle(_ availability: ComposerAvailabilityContext) -> some View {
        let source = availability.session?.box.reaction.source ?? .none
        let isBeatOn = ComposerControlCatalog.isBeatSource(source)
        return Button {
            guard let session = availability.session else { return }
            onDismissKeyboard()
            withAnimation(reduceMotion ? nil : HueAnimation.fast) {
                vm.commitComposerEdit(session) { box in
                    box.reaction.source = isBeatOn ? .none : .beat
                }
                if !isBeatOn { activeCompositionTab = .reaction }
            }
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "metronome.fill")
                    .font(.caption2.weight(.semibold))
                Text(isBeatOn ? "Beat On" : "Beat")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(isBeatOn ? Color.black.opacity(0.85) : HuePalette.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isBeatOn ? HuePalette.amber : HuePalette.amber.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .disabled(availability.session == nil)
        .accessibilityLabel("Beat reaction")
        .accessibilityValue(isBeatOn ? "on" : "off")
        .accessibilityHint(isBeatOn ? "Turns the beat reaction off" : "Turns the beat reaction on and switches to the React layer")
    }

    private func compositionSectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(HueFont.stageTag)
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Harmony chips belong to solid/gradient mode. Whether the target's
    /// lights can render them is the funnel's answer (`harmony`), applied by
    /// the gate around the row — a colourless room sees the row DISABLED
    /// under "NO COLOR LIGHTS HERE", an unread room under CHECKING; neither
    /// silently loses it.
    private func showHarmonyControls(_ availability: ComposerAvailabilityContext) -> Bool {
        let mode = availability.session?.box.palette.mode ?? .gradient
        return mode == .solid || mode == .gradient
    }

    /// Rules exposed in the chip row — excludes 4-color rules until color4 is added.
    private var filteredHarmonyRules: [HarmonyRule] {
        [.none, .complementary, .triadic, .analogous, .splitComplementary, .monochromatic]
    }

    // ──────────────────────────────────────────────
    // MARK: - Palette
    // ──────────────────────────────────────────────

    private func compositionPaletteControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "paintpalette.fill", title: "Color", subtitle: "Palette every light reads before motion and envelope.") {
            VStack(spacing: HueSpacing.sm) {

            // The mode is the layer's hero decision — four pads.
            ComposerChoiceControl(
                label: "Mode", controlID: "mode", vm: vm, availability: availability,
                items: PaletteConfig.Mode.allCases.map {
                    ChipPickerRow<PaletteConfig.Mode>.Item(value: $0, label: $0.rawValue.capitalized)
                },
                prominence: .pads,
                fallback: .gradient,
                read: { $0.palette.mode },
                write: { $0.palette.mode = $1 },
                afterCommit: { newMode in
                    // Auto-dismiss harmony when switching to a mode that ignores color fields
                    if newMode != .solid && newMode != .gradient && activeHarmonyRule != .none {
                        activeHarmonyRule = .none
                    }
                },
                onDismissKeyboard: onDismissKeyboard)

            let paletteMode = availability.session?.box.palette.mode ?? .gradient
            if paletteMode == .spectrum {
                // Spectrum derives its colour from hueShift + saturation and
                // never reads color1: the pad's hue axis was a dead control
                // here (review round, B-2). Hue shift is CHARACTER → the hero
                // knob; saturation is an AMOUNT → fader.
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    ComposerContinuousControl(
                        label: "Hue Shift", controlID: "hueShift", vm: vm, availability: availability,
                        style: .knob, range: -180...180, defaultValue: PaletteConfig().hueShift,
                        format: { "\(Int($0.rounded()))°" }, isHero: true,
                        read: { $0.palette.hueShift },
                        write: { $0.palette.hueShift = $1 })
                    ComposerContinuousControl(
                        label: "Saturation", controlID: "saturation", vm: vm, availability: availability,
                        style: .fader, range: 0...100, defaultValue: PaletteConfig().saturation,
                        format: { "\(Int($0.rounded()))%" }, isHero: true,
                        read: { $0.palette.saturation },
                        write: { $0.palette.saturation = $1 })
                    Spacer(minLength: 0)
                }
            } else if paletteMode == .temperature {
                // Temperature mode ignores color1/saturation — the pad was a
                // fully dead control surface here. Warmth is what the engine
                // reads (spectrum approximation live, real mirek one-shot).
                //
                // The CT-aware warmth knob: its range is the TARGET's
                // intersected mirek range (row 58) — on a narrower fixture the
                // knob travels exactly as far as the lights can go. With no
                // readable range the funnel answers CHECKING and the knob is
                // disabled; the fallback span is only somewhere for the stored
                // value to sit while disabled.
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    ComposerContinuousControl(
                        label: "Warmth", controlID: "temperature", vm: vm, availability: availability,
                        style: .knob,
                        range: availability.warmthRange ?? ComposerControlAvailability.fallbackWarmthRange,
                        defaultValue: 366,
                        format: StudioParamFormat.kelvin,
                        isHero: true,
                        // The readout is Kelvin; the range is mirek. Typing
                        // "2700K" must land at 2700 K, not clamp to 500 mirek
                        // (review round, B-7).
                        parseDraft: ComposerWarmthEntry.mirek(from:),
                        read: { Double($0.palette.temperature) },
                        write: { $0.palette.temperature = Int($1.rounded()) })
                    Spacer(minLength: 0)
                }
            } else {
                let colorPad = availability.resolve("colorPad")
                // `isColor: false`: the pad carries no coverage badge of its
                // own, so the caption is the ONE place a partial room's
                // "n OF m LIGHTS RESPOND" is stated (review round, B-1).
                ComposerControlGate(label: "Color", resolution: colorPad, isColor: false) {
                    hueSaturationPad(availability,
                                     interactive: ComposerControlAvailability.isInteractive(colorPad))
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
        if showHarmonyControls(availability) {
            let harmony = availability.resolve("harmony")
            let interactive = ComposerControlAvailability.isInteractive(harmony)
            ComposerControlGate(label: "Harmony", resolution: harmony, isColor: false) {
            VStack(alignment: .leading, spacing: 8) {
                // The rule is StudioView-scoped state (its onChange chain
                // rewrites the palette), so the chips bind to it directly;
                // the funnel's verdict is the floor on the setter.
                StageSteppedEncoder(
                    title: "Harmony",
                    items: filteredHarmonyRules.map {
                        ChipPickerRow<HarmonyRule>.Item(value: $0, label: $0.rawValue, icon: $0.icon)
                    },
                    selection: Binding(
                        get: { activeHarmonyRule },
                        set: { rule in
                            guard interactive else { return }
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                                activeHarmonyRule = rule
                            }
                        }
                    ),
                    prominence: .chips)

                if activeHarmonyRule != .none {
                    ComposerHarmonySwatches(vm: vm, availability: availability,
                                            isInteractive: interactive)

                    // Hint for static motion
                    if availability.session?.box.motion.pattern == .static {
                        Text("Try Cascade or Wave to spread harmony across lights")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.40))
                            .padding(.top, 2)
                    }
                }
            }
            }
        }
    }

    /// The pad itself is the shared StageKit `HueSaturationPad`; what stays
    /// here is what makes it the COMPOSER's pad — writing the live palette
    /// (harmony-aware) and pacing the REST burst per drag sample.
    private func hueSaturationPad(_ availability: ComposerAvailabilityContext,
                                  interactive: Bool) -> some View {
        let canonicalHSB: (h: Double, s: Double) = {
            guard let c = availability.session?.box.palette.color1 else { return (0.0, 1.0) }
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
                guard interactive, let session = availability.session else { return }
                vm.commitComposerEdit(session) { box in
                    // Per-sample: keep the REST mailbox in burst pacing while
                    // the finger moves (repeated calls extend the burst window).
                    box.triggerRESTBurst()
                    if activeHarmonyRule != .none {
                        let paletteColors = HarmonyEngine.palette(
                            rule: activeHarmonyRule,
                            rootHue: hue,
                            saturation: sat,
                            brightness: 1.0,
                            count: 3
                        )
                        let gamut = vm.activeCompositionGamut
                        box.palette.color1 = HueColorUtils.codableColor(from: paletteColors[0], gamut: gamut)
                        box.palette.color2 = HueColorUtils.codableColor(from: paletteColors[1], gamut: gamut)
                        if paletteColors.count >= 3 {
                            box.palette.color3 = HueColorUtils.codableColor(from: paletteColors[2], gamut: gamut)
                        } else {
                            box.palette.color3 = nil
                        }
                    } else {
                        box.palette.color1 = CodableColor(x: xy.x, y: xy.y)
                    }
                    box.palette.saturation = sat * 100
                }
            },
            onDragStateChanged: { dragging in
                guard interactive, let session = availability.session else { return }
                vm.commitComposerEdit(session) { box in
                    box.isColorPadInteracting = dragging
                    if !dragging { box.triggerRESTBurst() }
                }
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

    // ──────────────────────────────────────────────
    // MARK: - Motion
    // ──────────────────────────────────────────────

    private func compositionMotionControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "wind", title: "Motion", subtitle: "How color travels across lights over time.") {
            VStack(spacing: HueSpacing.sm) {

            PatternStripView(
                pattern: availability.session?.box.motion.pattern ?? .cascade,
                animated: vm.currentRoomEffect != nil
            )

            // One-tap pattern chips: every pattern visible at once (was a
            // 2-tap menu). Icons give each motion a recognizable signature.
            ComposerChoiceControl(
                label: "Pattern", controlID: "pattern", vm: vm, availability: availability,
                items: MotionConfig.Pattern.allCases.map { pattern in
                    ChipPickerRow<MotionConfig.Pattern>.Item(
                        value: pattern,
                        label: pattern.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        icon: Self.patternIcons[pattern.rawValue])
                },
                prominence: .chips,
                fallback: .cascade,
                read: { $0.motion.pattern },
                write: { $0.motion.pattern = $1 },
                onDismissKeyboard: onDismissKeyboard)

            // .static ignores speed/forward/spread/offset/mirror entirely —
            // showing them would be dead controls (the engine returns a
            // fixed phase). Direction and the rest are the supporting tier.
            let pattern = availability.session?.box.motion.pattern ?? .cascade
            if pattern != .static {
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    // Speed is a RATE — the layer's hero knob.
                    ComposerContinuousControl(
                        label: "Speed", controlID: "speed", vm: vm, availability: availability,
                        style: .knob, range: 0...100, defaultValue: MotionConfig().speed, isHero: true,
                        read: { $0.motion.speed },
                        write: { $0.motion.speed = $1 })
                    Spacer(minLength: 0)
                }

                if ComposerControlCatalog.isSpatialPattern(pattern) {
                    ComposerToggleControl(
                        label: "Forward", controlID: "forward", vm: vm, availability: availability,
                        read: { $0.motion.forward },
                        write: { $0.motion.forward = $1 })
                }
            } else {
                Text("Static holds every light on its palette color — pick a moving pattern to unlock speed and direction.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.40))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if pattern != .static {
                supportingTier(.motion, availability)
            }
        }
            }
    }

    // ──────────────────────────────────────────────
    // MARK: - Envelope
    // ──────────────────────────────────────────────

    private func compositionEnvelopeControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "waveform.path.ecg", title: "Brightness Shape", subtitle: "How brightness moves over time.") {
            VStack(spacing: HueSpacing.sm) {

            // The configured curve, live — what these controls actually do.
            EnvelopeStripView(envelope: availability.session?.box.envelope ?? EnvelopeConfig())

            ComposerChoiceControl(
                label: "Shape", controlID: "shape", vm: vm, availability: availability,
                items: EnvelopeConfig.Shape.allCases.map { shape in
                    ChipPickerRow<EnvelopeConfig.Shape>.Item(
                        value: shape, label: shape.rawValue.capitalized,
                        curveSamples: EnvelopeStripMath.thumbnail(for: shape))
                },
                prominence: .chips,
                fallback: .breathe,
                read: { $0.envelope.shape },
                write: { $0.envelope.shape = $1 },
                onDismissKeyboard: onDismissKeyboard)

            // .steady returns max brightness only — bpm/depth are no-ops.
            if (availability.session?.box.envelope.shape ?? .breathe) != .steady {
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    // BPM is a rate → knob; Depth is an amount → fader.
                    ComposerContinuousControl(
                        label: "BPM", controlID: "bpm", vm: vm, availability: availability,
                        style: .knob, range: 20...240, defaultValue: EnvelopeConfig().bpm, isHero: true,
                        read: { $0.envelope.bpm },
                        write: { $0.envelope.bpm = $1 })
                    ComposerContinuousControl(
                        label: "Depth", controlID: "depth", vm: vm, availability: availability,
                        style: .fader, range: 0...100, defaultValue: EnvelopeConfig().depth, isHero: true,
                        read: { $0.envelope.depth },
                        write: { $0.envelope.depth = $1 })
                    Spacer(minLength: 0)
                }
            }

            supportingTier(.envelope, availability)
        }
            }
    }

    // ──────────────────────────────────────────────
    // MARK: - Reaction
    // ──────────────────────────────────────────────

    private func compositionReactionControls(_ availability: ComposerAvailabilityContext) -> some View {
        StageCard(icon: "bolt.fill", title: "React", subtitle: "Audio and responsiveness layered on top.") {
            VStack(spacing: HueSpacing.sm) {

            ComposerChoiceControl(
                label: "Source", controlID: "source", vm: vm, availability: availability,
                items: ReactionConfig.Source.allCases.map { source in
                    ChipPickerRow<ReactionConfig.Source>.Item(
                        value: source,
                        label: Self.sourceLabels[source.rawValue]
                            ?? source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        icon: Self.sourceIcons[source.rawValue])
                },
                prominence: .chips,
                fallback: .none,
                read: { $0.reaction.source },
                write: { $0.reaction.source = $1 },
                onDismissKeyboard: onDismissKeyboard)

            let source = availability.session?.box.reaction.source ?? .none
            if source != .none {
                ComposerTargetPads(vm: vm, availability: availability)
            }

            reactionBeatControls(availability)
                .id("reactionBeatControls")   // ScrollViewReader auto-anchor target

            // Sensitivity shapes the MIC drive only — beat/onset sources use
            // punchDecay (in the beat panel) for their feel.
            if ComposerControlCatalog.isMicSource(source) {
                // Live level meter (polls the analysis engine, never starts
                // the mic) with the noise-gate threshold ticked on the bar.
                MicLevelMeterView(threshold: availability.session?.box.reaction.threshold)
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    ComposerContinuousControl(
                        label: "Sensitivity", controlID: "sensitivity", vm: vm, availability: availability,
                        style: .knob, range: 0...100, defaultValue: ReactionConfig().sensitivity, isHero: true,
                        read: { $0.reaction.sensitivity },
                        write: { $0.reaction.sensitivity = $1 })
                    Spacer(minLength: 0)
                }
            }

            if source != .none {
                supportingTier(.reaction, availability)
            }
        }
            }
    }

    /// Beat-clock section for the beat/onset/tap-tempo reaction sources —
    /// the shared BeatPanelView with Composer capabilities plus the reaction
    /// controls (punch decay, quantized color step, motion lock). One beat
    /// panel app-wide since R4-5. The panel stays session-unaware: the whole
    /// `ReactionConfig` it hands back is committed through the fence HERE.
    @ViewBuilder
    private func reactionBeatControls(_ availability: ComposerAvailabilityContext) -> some View {
        let source = availability.session?.box.reaction.source ?? .none
        if ComposerControlCatalog.isBeatSource(source) {
            BeatPanelView(
                capabilities: .composer,
                reaction: Binding(
                    get: { availability.session?.box.reaction ?? ReactionConfig() },
                    set: { newValue in
                        guard let session = availability.session else { return }
                        vm.commitComposerEdit(session) { $0.reaction = newValue }
                    }
                )
            )
        }
    }
}
