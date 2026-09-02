// ComposerLayerSheet.swift
// CastChroma — Composer supporting controls (Slice 3 convergence).
//
// The filename is historical (Xcode project churn is not worth a rename —
// execution plan §25): there is no sheet here any more. `ComposerControlCatalog`
// partitions each layer's controls into an ESSENTIAL tier and a SUPPORTING
// tier, and `ComposerSupportingControls` renders the supporting tier INSIDE
// the same StageCard as the essentials — quieter rows further down the one
// column, exactly as the Studio board's `.supporting` prominence band. There
// is no "Advanced" card, no reveal affordance and no detached destination:
// progressive reveal is contextual gating (a swell shape reveals attack/decay,
// a spatial pattern reveals direction), never a second surface to open.
//
// All bindings write the live CompositionParamBox directly, the same data
// path the panel uses (no debounce, no API calls; the render loop reads the
// box every frame).

import SwiftUI
import CoreGraphics

// MARK: - Control Catalog

/// Pure control-inventory functions: which controls are essential (the top of
/// the layer's card) vs supporting (the quieter rows below them, same card)
/// for a given layer state. Gating rules mirror what the engine actually
/// consumes — controls that are no-ops for the current pattern/shape/source
/// don't render at all.
enum ComposerControlCatalog {

    static func isMicSource(_ source: ReactionConfig.Source) -> Bool {
        switch source {
        case .micAmplitude, .micBass, .micMid, .micTreble: return true
        default: return false
        }
    }

    static func isBeatSource(_ source: ReactionConfig.Source) -> Bool {
        source == .beat || source == .onset || source == .tapTempo
    }

    /// Non-directional patterns hash per-light; direction/forward/mirror are no-ops.
    static func isSpatialPattern(_ pattern: MotionConfig.Pattern) -> Bool {
        pattern != .static && pattern != .scatter && pattern != .twinkle
    }

    /// Motion offset means different things per pattern — label it honestly.
    static func offsetLabel(for pattern: MotionConfig.Pattern) -> String {
        switch pattern {
        case .chase: return "Heads"
        case .twinkle: return "Density"
        default: return "Offset"
        }
    }

    static func essentialControlIDs(
        tab: CompositionLayerTab,
        paletteMode: PaletteConfig.Mode,
        motionPattern: MotionConfig.Pattern,
        envelopeShape: EnvelopeConfig.Shape,
        reactionSource: ReactionConfig.Source
    ) -> [String] {
        switch tab {
        case .palette:
            var ids = ["mode"]
            ids.append(paletteMode == .temperature ? "temperature" : "colorPad")
            if paletteMode == .solid || paletteMode == .gradient { ids.append("harmony") }
            return ids
        case .motion:
            var ids = ["pattern"]
            // .static ignores every motion field (returns a fixed phase).
            guard motionPattern != .static else { return ids }
            ids.append("speed")
            if isSpatialPattern(motionPattern) { ids.append("forward") }
            return ids
        case .envelope:
            var ids = ["shape"]
            // .steady returns maxBrightness only — bpm/depth are no-ops.
            guard envelopeShape != .steady else { return ids }
            ids += ["bpm", "depth"]
            return ids
        case .reaction:
            var ids = ["source"]
            guard reactionSource != .none else { return ids }
            ids.append("targets")
            if isBeatSource(reactionSource) { ids.append("beatPanel") }
            // Sensitivity/threshold shape the MIC drive only; beat/onset use punchDecay.
            if isMicSource(reactionSource) { ids.append("sensitivity") }
            return ids
        }
    }

    static func supportingControlIDs(
        tab: CompositionLayerTab,
        paletteMode: PaletteConfig.Mode,
        motionPattern: MotionConfig.Pattern,
        envelopeShape: EnvelopeConfig.Shape,
        reactionSource: ReactionConfig.Source
    ) -> [String] {
        switch tab {
        case .palette:
            var ids: [String] = []
            if paletteMode == .spectrum { ids += ["hueShift", "saturation"] }
            ids += ["randomize", "dynamicSceneExport"]
            return ids
        case .motion:
            guard motionPattern != .static else { return [] }
            var ids: [String] = []
            if isSpatialPattern(motionPattern) { ids.append("direction") }
            ids += ["spread", "offset"]
            if isSpatialPattern(motionPattern) { ids.append("mirror") }
            return ids
        case .envelope:
            var ids: [String] = []
            if envelopeShape == .swell { ids += ["attack", "decay"] }
            if envelopeShape == .pulse { ids.append("dutyCycle") }
            if envelopeShape != .steady { ids.append("minBrightness") }
            ids.append("maxBrightness")
            return ids
        case .reaction:
            switch reactionSource {
            case .none:
                return []
            case .micAmplitude, .micBass, .micMid, .micTreble:
                return ["smoothing", "threshold", "intensity"]
            case .tapTempo, .beat, .onset:
                return ["intensity"]
            }
        }
    }

    /// Every control the layer renders for this state, essential first — the
    /// list a migration test walks to prove nothing that used to live behind
    /// "Advanced" silently disappeared.
    static func renderedControlIDs(
        tab: CompositionLayerTab,
        paletteMode: PaletteConfig.Mode,
        motionPattern: MotionConfig.Pattern,
        envelopeShape: EnvelopeConfig.Shape,
        reactionSource: ReactionConfig.Source
    ) -> [String] {
        essentialControlIDs(tab: tab, paletteMode: paletteMode, motionPattern: motionPattern,
                            envelopeShape: envelopeShape, reactionSource: reactionSource)
        + supportingControlIDs(tab: tab, paletteMode: paletteMode, motionPattern: motionPattern,
                               envelopeShape: envelopeShape, reactionSource: reactionSource)
    }
}

// MARK: - Capability truth (Slice 3, S3-4)

/// One instant of capability truth for the Composer surface: the running
/// composition's card, its exact target, and the resolver snapshot built from
/// CACHED lights (`targetSnapshot(for:)` — no fetch, spec §27; it also reads
/// the orchestrator's inventory generation, so the surface re-resolves when
/// the bridge finally answers).
///
/// Built ONCE per panel render and handed down, so every control on the page
/// answers against the same instant — never one control against a snapshot
/// and its neighbour against a fresh one.
///
/// No running composition ⇒ no snapshot ⇒ every resolution is nil ⇒ every
/// control reads CHECKING and is not interactive. Nil never means yes.
@MainActor
struct ComposerAvailabilityContext {
    let cardID: String?
    /// The EXACT target the running composition addresses — not the room
    /// selector's current value re-read at each use.
    let room: RoomDisplayItem?
    let snapshot: CustomizationTargetSnapshot?
    /// The edit session for this render (S3-5): the running identity and
    /// the live box, captured once. Every write on the page commits through
    /// it; nil when the row has no live box (one-shot, recovered mirror).
    let session: ComposerEditSession?

    init(vm: StudioViewModel) {
        if let effect = vm.currentRoomEffect {
            cardID = effect.card.id
            room = effect.room
            snapshot = vm.targetSnapshot(for: effect)
            session = vm.composerEditSession(for: effect)
        } else {
            cardID = nil
            room = vm.selectedRoom
            snapshot = nil
            session = nil
        }
    }

    func resolve(_ controlID: String) -> StudioBoardResolution? {
        guard let cardID, let snapshot else { return nil }
        return ComposerControlAvailability.resolve(cardID: cardID, controlID: controlID,
                                                   snapshot: snapshot)
    }

    func isInteractive(_ controlID: String) -> Bool {
        ComposerControlAvailability.isInteractive(resolve(controlID))
    }

    /// The Warmth control's authoring range: the target's intersected mirek
    /// range, or nil (the control then resolves CHECKING and is disabled).
    var warmthRange: ClosedRange<Double>? {
        ComposerControlAvailability.warmthRange(snapshot: snapshot)
    }
}

/// A setter that drops its write unless the funnel said the control is
/// interactive — the setter-level floor beneath `.disabled`, which does not
/// close raw gestures (a pad drag, a chip's tap gesture) the way it closes
/// a `Control`.
func composerGuarded<Value>(_ interactive: Bool, _ binding: Binding<Value>) -> Binding<Value> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            guard interactive else { return }
            binding.wrappedValue = newValue
        }
    )
}

/// The funnel's answer, APPLIED, around one Composer control — the shape
/// Guard 15(k) pins for the Studio board: `.disabled` on the verdict, the
/// verdict's opacity on the control (not on the note), and the note beside
/// it in words a VoiceOver user hears with the control's name.
///
/// `.hidden` renders nothing (an orphaned control id). A nil resolution —
/// no snapshot — renders the control DISABLED under CHECKING, because a
/// control that vanishes while the bridge is still being asked is the silent
/// removal the honesty rule forbids.
struct ComposerControlGate<Content: View>: View {
    let label: String
    let resolution: StudioBoardResolution?
    var isColor: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if ComposerControlAvailability.rendersControl(resolution) {
            let interactive = ComposerControlAvailability.isInteractive(resolution)
            let opacity = ComposerControlAvailability.opacity(resolution)
            let note = ComposerControlAvailability.note(for: resolution, isColor: isColor)
            VStack(alignment: .leading, spacing: 3) {
                // Opacity belongs to the CONTROL, not the pair: a note nested
                // inside a dimmed wrapper is the least legible thing on the
                // page, and it is the sentence explaining why the control is
                // dead.
                content()
                    .disabled(!interactive)
                    .opacity(opacity)
                if let note {
                    Text(note)
                        .font(HueFont.stageTag)
                        .foregroundStyle(HuePalette.amber.opacity(0.65))
                        .tracking(0.6)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(label): \(note)")
                }
            }
        }
    }
}

// MARK: - Supporting Controls

/// The supporting tier of one layer tab, rendered by the editor panel INSIDE
/// that layer's card, directly under the essentials. One column, one card,
/// one identity lifetime — the old `.id(activeCompositionTab)` split put the
/// essentials and the "Advanced" card on different lifetimes, so a tab switch
/// rebuilt one half of the page and not the other.
struct ComposerSupportingControls: View {
    let vm: StudioViewModel
    /// Explicit, not `@Environment`: see `CompositionEditorPanel`.
    let orchestrator: UnifiedOrchestrator
    /// The panel's one instant of capability truth for this render.
    let availability: ComposerAvailabilityContext
    let tab: CompositionLayerTab

    @State private var showEntertainmentBuilder = false
    @State private var showDynamicScenePrompt = false
    @State private var dynamicSceneName = ""

    var body: some View {
        VStack(spacing: HueSpacing.sm) {
            switch tab {
            case .palette: paletteSupporting
            case .motion: motionSupporting
            case .envelope: envelopeSupporting
            case .reaction: reactionSupporting
            }
        }
        // Whether directional motion is offered is now a room-membership
        // question, so the answer has to come from a warm cache. Composer can be
        // opened without ever visiting Studio, which is the only other surface
        // that warms — without this the controls would hide themselves on a cold
        // launch and tell the user to create an area they already have.
        .task(id: availability.room?.id) {
            await orchestrator.warmEntertainmentCaches(for: availability.room)
        }
    }

    // ── Palette ───────────────────────────────────────────────

    @ViewBuilder
    private var paletteSupporting: some View {
        if (availability.session?.box.palette.mode ?? .gradient) == .spectrum {
            HStack(alignment: .top, spacing: HueSpacing.lg) {
                // Hue shift is CHARACTER (an offset around the wheel) → knob;
                // saturation is an AMOUNT → fader. Spectrum consumes saturation
                // directly; before this control it was only settable as a side
                // effect of the hue pad (which also wrote an ignored color1 in
                // spectrum mode).
                ComposerContinuousControl(
                    label: "Hue Shift", controlID: "hueShift", vm: vm, availability: availability,
                    style: .knob, range: -180...180, defaultValue: PaletteConfig().hueShift,
                    format: { "\(Int($0.rounded()))°" },
                    read: { $0.palette.hueShift },
                    write: { $0.palette.hueShift = $1 })
                ComposerContinuousControl(
                    label: "Saturation", controlID: "saturation", vm: vm, availability: availability,
                    style: .fader, range: 0...100, defaultValue: PaletteConfig().saturation,
                    format: { "\(Int($0.rounded()))%" },
                    read: { $0.palette.saturation },
                    write: { $0.palette.saturation = $1 })
                Spacer(minLength: 0)
            }
        }

        ComposerToggleControl(
            label: "Randomize", controlID: "randomize", vm: vm, availability: availability,
            read: { $0.palette.randomize },
            write: { $0.palette.randomize = $1 })

        // Round 3 (E): export this palette as a NATIVE Hue dynamic scene —
        // the bridge cycles it forever with the app closed. An ACTION, not a
        // control — it closes the card, below the last control row. Gated
        // like the colour controls: a dynamic scene of a palette no light
        // here can render is a bridge write with nothing to show for it.
        let export = availability.resolve("dynamicSceneExport")
        ComposerControlGate(label: "Save as Hue dynamic scene", resolution: export) {
        Button {
            guard ComposerControlAvailability.isInteractive(export) else { return }
            dynamicSceneName = ""
            showDynamicScenePrompt = true
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save as Hue dynamic scene")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Loops on the bridge — works with the app closed")
                        .font(.system(size: 10))
                        .opacity(0.55)
                }
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .alert("Save as Hue Dynamic Scene", isPresented: $showDynamicScenePrompt) {
            TextField("Scene name", text: $dynamicSceneName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = dynamicSceneName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await exportDynamicScene(named: name) }
            }
        } message: {
            Text("The bridge cycles this palette on its own — no phone needed. It appears in your Scenes tab.")
        }
        }
    }

    /// Builds a native dynamic scene from the live palette layer and POSTs
    /// it to the room's own bridge. One POST — no loops, no session.
    private func exportDynamicScene(named name: String) async {
        guard let room = availability.room,
              let groupedLightID = room.groupedLightID,
              let api = orchestrator.hueClient(for: room.bridgeID),
              let box = availability.session?.box else {
            vm.statusMessage = "⚠ Select a room and composition first"
            return
        }
        // Sample the palette through the same function the Composer renders
        // with. Reading color1/color2 straight off the config — as this used to
        // — exports the wrong scene in spectrum mode (the colours come from the
        // hue wheel) and in temperature mode (they come from mirek).
        let recipe = BridgeDynamicSceneExporter.recipe(
            palette: box.palette,
            motion: box.motion,
            envelope: box.envelope,
            gamut: vm.activeCompositionGamut
        )
        let paletteXY = recipe.palette.map { (x: $0.x, y: $0.y) }

        do {
            let ids = Set(try await api.fetchLightIDsForGroup(groupedLightID: groupedLightID))
            let lights = try await api.fetchLights().filter { ids.contains($0.id) }
            guard !lights.isEmpty else {
                vm.statusMessage = "⚠ No lights found in '\(room.name)'"
                return
            }
            let request = CreateSceneRequest.dynamicScene(
                name: name,
                groupID: room.id,
                groupRtype: room.kind == .zone ? "zone" : "room",
                lights: lights,
                paletteXY: paletteXY,
                brightness: recipe.brightness,
                speed: recipe.speed
            )
            let sceneID = try await api.createSceneReturningID(request)
            // R4 Scenes block: remember provenance so the Scenes tab can show
            // the STUDIO badge, and refresh so the scene is already there
            // when the user hops over.
            if let bridgeID = room.bridgeID {
                SceneProvenanceStore.shared.markStudioExported(bridgeID: bridgeID, sceneID: sceneID)
            }
            vm.statusMessage = BridgeDynamicSceneExporter.successMessage(name: name, willAnimate: recipe.willAnimate)
            // A scene is bridge-run and genuinely keeps playing with the app
            // closed — but it has NO ownership manifest, so Packet 8 will never
            // recover it and ChromaGlow can never stop it. Say where it lives
            // and where to stop it: promising a Stop we cannot deliver is what
            // leaves someone hunting for lights they cannot turn off.
            vm.studioNotice = StudioViewModel.StudioNotice(
                message: BridgeSaveCopy.savedAsSceneNotStoppable)
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch HueAPIError.decodingFailed {
            // POST executed — the scene exists on the bridge; only the id
            // parse failed. Success without a provenance badge.
            vm.statusMessage = BridgeDynamicSceneExporter.successMessage(name: name, willAnimate: recipe.willAnimate)
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch {
            vm.statusMessage = "⚠ Couldn't save the scene — \(error.localizedDescription)"
        }
    }

    // ── Motion ────────────────────────────────────────────────

    @ViewBuilder
    private var motionSupporting: some View {
        let pattern = availability.session?.box.motion.pattern ?? .cascade

        if ComposerControlCatalog.isSpatialPattern(pattern) {
            // Directional motion needs the area that actually contains THIS
            // target's lights — a different room's area on the same bridge
            // would aim the motion at the wrong lights. MEMBERSHIP is the
            // gate (not "can this bridge stream": forward/mirror work on REST
            // index positions), answered for the exact running target. The
            // warm below is what lets the answer come from real membership
            // rather than a cold cache.
            ComposerControlGate(label: "Direction", resolution: availability.resolve("direction")) {
                if orchestrator.activeEntertainmentConfig(for: availability.room) != nil {
                    directionControl
                } else {
                    entertainmentAreaPrompt
                }
            }
        }

        HStack(alignment: .top, spacing: HueSpacing.lg) {
            // Spread and offset/heads are CHARACTER → knobs; twinkle's
            // "Density" is an AMOUNT → fader.
            ComposerContinuousControl(
                label: "Spread", controlID: "spread", vm: vm, availability: availability,
                style: .knob, range: 0...100, defaultValue: MotionConfig().spread,
                read: { $0.motion.spread },
                write: { $0.motion.spread = $1 })
            ComposerContinuousControl(
                label: ComposerControlCatalog.offsetLabel(for: pattern), controlID: "offset",
                vm: vm, availability: availability,
                style: pattern == .twinkle ? .fader : .knob,
                range: 0...100, defaultValue: MotionConfig().offset,
                read: { $0.motion.offset },
                write: { $0.motion.offset = $1 })
            Spacer(minLength: 0)
        }

        if ComposerControlCatalog.isSpatialPattern(pattern) {
            ComposerToggleControl(
                label: "Mirror", controlID: "mirror", vm: vm, availability: availability,
                read: { $0.motion.mirror },
                write: { $0.motion.mirror = $1 })
        }
    }

    // ── Envelope ──────────────────────────────────────────────

    @ViewBuilder
    private var envelopeSupporting: some View {
        let shape = availability.session?.box.envelope.shape ?? .breathe

        // The live curve preview renders ONCE, at the top of the card with the
        // essentials — it used to render a second time here, when this tier
        // lived on its own card.

        // Shape-specific controls (the engine has always consumed these):
        // attack, decay and duty cycle are RATES/character → knobs.
        if shape == .swell || shape == .pulse {
            HStack(alignment: .top, spacing: HueSpacing.lg) {
                if shape == .swell {
                    ComposerContinuousControl(
                        label: "Attack", controlID: "attack", vm: vm, availability: availability,
                        style: .knob, range: 0...100, defaultValue: EnvelopeConfig().attack,
                        read: { $0.envelope.attack },
                        write: { $0.envelope.attack = $1 })
                    ComposerContinuousControl(
                        label: "Decay", controlID: "decay", vm: vm, availability: availability,
                        style: .knob, range: 0...100, defaultValue: EnvelopeConfig().decay,
                        read: { $0.envelope.decay },
                        write: { $0.envelope.decay = $1 })
                }
                if shape == .pulse {
                    ComposerContinuousControl(
                        label: "Duty Cycle", controlID: "dutyCycle", vm: vm, availability: availability,
                        style: .knob, range: 10...90, defaultValue: EnvelopeConfig().dutyCycle,
                        format: { "\(Int($0.rounded()))%" },
                        read: { $0.envelope.dutyCycle },
                        write: { $0.envelope.dutyCycle = $1 })
                }
                Spacer(minLength: 0)
            }
        }

        // Brightness floor and ceiling are LEVELS → faders.
        HStack(alignment: .top, spacing: HueSpacing.lg) {
            if shape != .steady {
                ComposerContinuousControl(
                    label: "Min Brightness", controlID: "minBrightness", vm: vm, availability: availability,
                    style: .fader, range: 0...50, defaultValue: EnvelopeConfig().minBrightness,
                    read: { $0.envelope.minBrightness },
                    write: { $0.envelope.minBrightness = $1 })
            }
            ComposerContinuousControl(
                label: "Max Brightness", controlID: "maxBrightness", vm: vm, availability: availability,
                style: .fader, range: 50...100, defaultValue: EnvelopeConfig().maxBrightness,
                read: { $0.envelope.maxBrightness },
                write: { $0.envelope.maxBrightness = $1 })
            Spacer(minLength: 0)
        }
    }

    // ── Reaction ──────────────────────────────────────────────

    @ViewBuilder
    private var reactionSupporting: some View {
        let source = availability.session?.box.reaction.source ?? .none

        HStack(alignment: .top, spacing: HueSpacing.lg) {
            if ComposerControlCatalog.isMicSource(source) {
                // The level meter renders ONCE, with the essentials above.
                // Smoothing (one-pole response lag) and threshold (noise gate)
                // shape the mic drive's CHARACTER → knobs.
                ComposerContinuousControl(
                    label: "Smoothing", controlID: "smoothing", vm: vm, availability: availability,
                    style: .knob, range: 0...100, defaultValue: ReactionConfig().smoothing,
                    read: { $0.reaction.smoothing },
                    write: { $0.reaction.smoothing = $1 })
                ComposerContinuousControl(
                    label: "Threshold", controlID: "threshold", vm: vm, availability: availability,
                    style: .knob, range: 0...100, defaultValue: ReactionConfig().threshold,
                    read: { $0.reaction.threshold },
                    write: { $0.reaction.threshold = $1 })
            }
            if source != .none {
                // How hard the reaction hits — an AMOUNT → fader.
                ComposerContinuousControl(
                    label: "Intensity", controlID: "intensity", vm: vm, availability: availability,
                    style: .fader, range: 0...100, defaultValue: ReactionConfig().intensity,
                    read: { $0.reaction.intensity },
                    write: { $0.reaction.intensity = $1 })
            }
            Spacer(minLength: 0)
        }
    }

    // ── Direction cluster (moved wholesale from the editor panel) ──

    /// Auto (PCA, `-1`) plus the eight compass presets.
    private static let directionPresets: [ChipPickerRow<Double>.Item] =
        [ChipPickerRow<Double>.Item(value: -1, label: "Auto")]
        + [("→", 0.0), ("↗", 45.0), ("↑", 90.0), ("↖", 135.0),
           ("←", 180.0), ("↙", 225.0), ("↓", 270.0), ("↘", 315.0)].map {
            ChipPickerRow<Double>.Item(value: $0.1, label: $0.0)
        }

    /// Which preset the current angle sits on (within the 5° snap), or the
    /// exact angle itself when it is not a preset.
    private static func presetSelection(for angle: Double) -> Double {
        guard angle >= 0 else { return -1 }
        for preset in directionPresets where preset.value >= 0 {
            if abs(angle - preset.value) < 5 || abs(angle - preset.value - 360) < 5 {
                return preset.value
            }
        }
        return angle
    }

    private var directionControl: some View {
        let angle = availability.session?.box.motion.motionAngle ?? -1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: HueSpacing.lg) {
                // Mini-map: a PREVIEW of where the lights sit and which way
                // the motion travels — not a control.
                spatialMiniMap

                // The angle is CHARACTER → the shared knob (exact entry,
                // double-tap, adjustable accessibility), replacing the
                // hand-rolled dial. `Auto` (-1) reads as 0° on the knob; the
                // pads below are where Auto is chosen.
                StageKnob(
                    title: "Direction",
                    value: Binding(
                        get: { max(0, angle) },
                        set: { newAngle in
                            let snapped = (newAngle / 5).rounded() * 5
                            recomputeSpatialPositions(angle: snapped.truncatingRemainder(dividingBy: 360))
                        }
                    ),
                    range: 0...360,
                    defaultValue: 0,
                    format: { angle < 0 ? "Auto" : "\(Int($0.rounded()))°" },
                    diameter: 60)
                Spacer(minLength: 0)
            }

            // Direction presets — discrete decisions → chips (nine of them,
            // so the scrollable row rather than pads).
            StageSteppedEncoder(
                title: "Preset",
                items: Self.directionPresets,
                selection: Binding(
                    get: { Self.presetSelection(for: angle) },
                    set: { preset in
                        if preset < 0 {
                            guard let session = availability.session else { return }
                            vm.commitComposerEdit(session) { box in
                                box.motion.motionAngle = -1
                                box.triggerRESTBurst()
                            }
                        } else {
                            recomputeSpatialPositions(angle: preset)
                        }
                        HapticManager.shared.medium()
                    }
                ),
                prominence: .chips)
        }
    }

    private var spatialMiniMap: some View {
        let mapSize: CGFloat = 80
        let currentAngle = max(0, availability.session?.box.motion.motionAngle ?? 0)

        return ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )

            // Direction arrow through center
            let arrowRad: CGFloat = (CGFloat(currentAngle) - 90) * .pi / 180
            let arrowCos: CGFloat = CoreGraphics.cos(arrowRad)
            let arrowSin: CGFloat = CoreGraphics.sin(arrowRad)
            Path { path in
                let cx = mapSize / 2, cy = mapSize / 2
                let len: CGFloat = mapSize / 2 - 8
                path.move(to: CGPoint(
                    x: cx - arrowCos * len * 0.3,
                    y: cy - arrowSin * len * 0.3
                ))
                path.addLine(to: CGPoint(
                    x: cx + arrowCos * len,
                    y: cy + arrowSin * len
                ))
            }
            .stroke(
                HuePalette.amber.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
            )

            // Light position dots
            if let config = orchestrator.activeEntertainmentConfig(for: availability.room) {
                let channels = config.channels
                // Normalize positions to fit in map
                let xs = channels.map { $0.position.x }
                let zs = channels.map { $0.position.z }
                let minX = xs.min() ?? -1, maxX = xs.max() ?? 1
                let minZ = zs.min() ?? -1, maxZ = zs.max() ?? 1
                let rangeX = max(maxX - minX, 0.01)
                let rangeZ = max(maxZ - minZ, 0.01)
                let scale = max(rangeX, rangeZ)

                ForEach(0..<channels.count, id: \.self) { i in
                    let ch = channels[i]
                    let nx = (ch.position.x - minX) / scale
                    let nz = (ch.position.z - minZ) / scale
                    // Center in map with padding
                    let pad: CGFloat = 14
                    let usable = mapSize - pad * 2
                    let dotX = pad + CGFloat(nx) * usable
                    let dotY = pad + CGFloat(nz) * usable
                    let dotColor = paletteSwatchColor(at: i % 3)

                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                        .shadow(color: dotColor.opacity(0.5), radius: 3)
                        .position(x: dotX, y: dotY)
                }
            }
        }
        .frame(width: mapSize, height: mapSize)
        .animation(.interactiveSpring(response: 0.3), value: currentAngle)
    }

    private func paletteSwatchColor(at index: Int) -> Color {
        guard let box = availability.session?.box else { return .gray }
        let c: CodableColor
        switch index {
        case 0: c = box.palette.color1
        case 1: c = box.palette.color2
        case 2: c = box.palette.color3 ?? box.palette.color2
        default: c = box.palette.color1
        }
        return HueColorUtils.color(fromX: c.x, y: c.y, brightness: 100)
    }

    private var entertainmentAreaPrompt: some View {
        Button {
            showEntertainmentBuilder = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Entertainment Area")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Unlock directional motion across your room")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .foregroundStyle(HuePalette.amber.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HuePalette.amber.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(HuePalette.amber.opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showEntertainmentBuilder) {
            EntertainmentConfigBuilderView { _ in
                // Writing the new config straight into the cache is no longer
                // enough: whether it belongs to THIS room is decided by the
                // entertainment-service → device → light map, which only the
                // bridge can answer. Re-warm, then recompute from the selection.
                let room = availability.room
                Task {
                    await orchestrator.warmEntertainmentCaches(for: room, force: true)
                    recomputeSpatialPositions(angle: max(0, availability.session?.box.motion.motionAngle ?? 0))
                }
            }
            .environment(orchestrator)
        }
    }

    /// Recompute spatial positions when the angle changes.
    /// Called from Binding setters and chip taps so position recompute happens
    /// exactly once per user edit (CompositionParamBox is @Observable, but an
    /// onChange would also fire on programmatic writes like preset loads).
    private func recomputeSpatialPositions(angle: Double) {
        guard let config = orchestrator.activeEntertainmentConfig(for: availability.room),
              let session = availability.session else { return }
        let newPositions = CompositionEngine.computeSpatialPositionsForEntertainment(
            channels: config.channels,
            motionAngle: angle
        )
        vm.commitComposerEdit(session) { box in
            box.motion.motionAngle = angle
            guard !newPositions.isEmpty else { return }
            // Start smooth lerp transition
            box.targetSpatialPositions = newPositions
            box.spatialLerpProgress = 0.0
            box.triggerRESTBurst()
        }
    }
}
