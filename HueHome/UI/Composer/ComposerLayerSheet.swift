// ComposerLayerSheet.swift
// CastChroma — Composer advanced controls (adjustment-settings revamp).
//
// The "+N more" surface for the active composer layer tab. The editor panel
// keeps 3-5 essential controls inline (COMPOSER_SPEC progressive-disclosure
// model); everything else renders here — in a StageSheetScaffold sheet from
// the more button, or inline via ComposerAdvancedControls when the tray is
// dragged up. All bindings write the live CompositionParamBox directly, the
// same data path the panel uses (no debounce, no API calls; the render loop
// reads the box every frame).

import SwiftUI
import CoreGraphics

// MARK: - Control Catalog

/// Pure control-inventory functions: which controls are essential (inline in
/// the tray) vs advanced (sheet / expanded tray) for a given layer state.
/// Gating rules mirror what the engine actually consumes — controls that are
/// no-ops for the current pattern/shape/source don't render at all.
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

    static func advancedControlIDs(
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

    /// Convenience: advanced-control count for the live box state.
    @MainActor
    static func advancedCount(tab: CompositionLayerTab, box: CompositionParamBox?) -> Int {
        advancedControlIDs(
            tab: tab,
            paletteMode: box?.palette.mode ?? .gradient,
            motionPattern: box?.motion.pattern ?? .cascade,
            envelopeShape: box?.envelope.shape ?? .breathe,
            reactionSource: box?.reaction.source ?? .none
        ).count
    }
}

// MARK: - Layer Sheet

/// StageSheetScaffold wrapper around the advanced controls — the "+N more"
/// target from the composer editor panel.
struct ComposerLayerSheet: View {
    let vm: StudioViewModel
    let tab: CompositionLayerTab

    var body: some View {
        StageSheetScaffold(title: "\(tab.title) · Advanced") {
            StageCard(icon: tab.symbolName, title: tab.title) {
                ComposerAdvancedControls(vm: vm, tab: tab)
            }
        }
    }
}

// MARK: - Advanced Controls

/// The advanced control set for one layer tab. Rendered inside the sheet
/// AND inline in the editor panel when the tray is dragged up.
struct ComposerAdvancedControls: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    let vm: StudioViewModel
    let tab: CompositionLayerTab

    @State private var showEntertainmentBuilder = false
    @State private var showDynamicScenePrompt = false
    @State private var dynamicSceneName = ""

    var body: some View {
        VStack(spacing: HueSpacing.sm) {
            switch tab {
            case .palette: paletteAdvanced
            case .motion: motionAdvanced
            case .envelope: envelopeAdvanced
            case .reaction: reactionAdvanced
            }
        }
    }

    // ── Palette ───────────────────────────────────────────────

    @ViewBuilder
    private var paletteAdvanced: some View {
        if (vm.activeCompositionBox?.palette.mode ?? .gradient) == .spectrum {
            StageSlider(
                title: "Hue Shift",
                value: Binding(
                    get: { vm.activeCompositionBox?.palette.hueShift ?? 0 },
                    set: { vm.activeCompositionBox?.palette.hueShift = $0 }
                ),
                range: -180...180,
                format: { "\(Int($0.rounded()))°" }
            )
            // Spectrum consumes saturation directly; before this slider it was
            // only settable as a side effect of the hue pad (which also wrote
            // an ignored color1 in spectrum mode).
            StageSlider(
                title: "Saturation",
                value: Binding(
                    get: { vm.activeCompositionBox?.palette.saturation ?? 100 },
                    set: { vm.activeCompositionBox?.palette.saturation = $0 }
                ),
                range: 0...100,
                format: { "\(Int($0.rounded()))%" }
            )
        }

        StageToggleRow(
            title: "Randomize",
            isOn: Binding(
                get: { vm.activeCompositionBox?.palette.randomize ?? false },
                set: { vm.activeCompositionBox?.palette.randomize = $0 }
            )
        )

        // Round 3 (E): export this palette as a NATIVE Hue dynamic scene —
        // the bridge cycles it forever with the app closed.
        Button {
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

    /// Builds a native dynamic scene from the live palette layer and POSTs
    /// it to the room's own bridge. One POST — no loops, no session.
    private func exportDynamicScene(named name: String) async {
        guard let room = vm.selectedRoom,
              let groupedLightID = room.groupedLightID,
              let api = orchestrator.hueClient(for: room.bridgeID),
              let box = vm.activeCompositionBox else {
            vm.statusMessage = "⚠ Select a room and composition first"
            return
        }
        var paletteXY: [(x: Double, y: Double)] = [
            (box.palette.color1.x, box.palette.color1.y),
            (box.palette.color2.x, box.palette.color2.y),
        ]
        if let c3 = box.palette.color3 { paletteXY.append((c3.x, c3.y)) }

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
                brightness: box.envelope.maxBrightness,
                speed: max(0.1, min(1.0, box.motion.speed / 100.0))
            )
            let sceneID = try await api.createSceneReturningID(request)
            // R4 Scenes block: remember provenance so the Scenes tab can show
            // the STUDIO badge, and refresh so the scene is already there
            // when the user hops over.
            if let bridgeID = room.bridgeID {
                SceneProvenanceStore.shared.markStudioExported(bridgeID: bridgeID, sceneID: sceneID)
            }
            vm.statusMessage = "'\(name)' saved as a dynamic scene ✓ — find it in Scenes"
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch HueAPIError.decodingFailed {
            // POST executed — the scene exists on the bridge; only the id
            // parse failed. Success without a provenance badge.
            vm.statusMessage = "'\(name)' saved as a dynamic scene ✓ — find it in Scenes"
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch {
            vm.statusMessage = "⚠ Couldn't save the scene — \(error.localizedDescription)"
        }
    }

    // ── Motion ────────────────────────────────────────────────

    @ViewBuilder
    private var motionAdvanced: some View {
        let pattern = vm.activeCompositionBox?.motion.pattern ?? .cascade

        if ComposerControlCatalog.isSpatialPattern(pattern) {
            if orchestrator.activeEntertainmentConfig(for: vm.selectedRoom) != nil {
                directionControl
            } else {
                entertainmentAreaPrompt
            }
        }

        StageSlider(
            title: "Spread",
            value: Binding(
                get: { vm.activeCompositionBox?.motion.spread ?? 70 },
                set: { vm.activeCompositionBox?.motion.spread = $0 }
            ),
            range: 0...100
        )

        StageSlider(
            title: ComposerControlCatalog.offsetLabel(for: pattern),
            value: Binding(
                get: { vm.activeCompositionBox?.motion.offset ?? 50 },
                set: { vm.activeCompositionBox?.motion.offset = $0 }
            ),
            range: 0...100
        )

        if ComposerControlCatalog.isSpatialPattern(pattern) {
            StageToggleRow(
                title: "Mirror",
                isOn: Binding(
                    get: { vm.activeCompositionBox?.motion.mirror ?? false },
                    set: { vm.activeCompositionBox?.motion.mirror = $0 }
                )
            )
        }
    }

    // ── Envelope ──────────────────────────────────────────────

    @ViewBuilder
    private var envelopeAdvanced: some View {
        let shape = vm.activeCompositionBox?.envelope.shape ?? .breathe

        // Shape-specific controls (the engine has always consumed these).
        if shape == .swell {
            StageSlider(
                title: "Attack",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.attack ?? 50 },
                    set: { vm.activeCompositionBox?.envelope.attack = $0 }
                ),
                range: 0...100
            )
            StageSlider(
                title: "Decay",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.decay ?? 50 },
                    set: { vm.activeCompositionBox?.envelope.decay = $0 }
                ),
                range: 0...100
            )
        }
        if shape == .pulse {
            StageSlider(
                title: "Duty Cycle",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.dutyCycle ?? 50 },
                    set: { vm.activeCompositionBox?.envelope.dutyCycle = $0 }
                ),
                range: 10...90
            )
        }

        if shape != .steady {
            StageSlider(
                title: "Min Brightness",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.minBrightness ?? 10 },
                    set: { vm.activeCompositionBox?.envelope.minBrightness = $0 }
                ),
                range: 0...50
            )
        }
        StageSlider(
            title: "Max Brightness",
            value: Binding(
                get: { vm.activeCompositionBox?.envelope.maxBrightness ?? 100 },
                set: { vm.activeCompositionBox?.envelope.maxBrightness = $0 }
            ),
            range: 50...100
        )
    }

    // ── Reaction ──────────────────────────────────────────────

    @ViewBuilder
    private var reactionAdvanced: some View {
        let source = vm.activeCompositionBox?.reaction.source ?? .none

        if ComposerControlCatalog.isMicSource(source) {
            // The engine has consumed smoothing (one-pole response lag) all
            // along — this is its first slider.
            StageSlider(
                title: "Smoothing",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.smoothing ?? 30 },
                    set: { vm.activeCompositionBox?.reaction.smoothing = $0 }
                ),
                range: 0...100
            )
            StageSlider(
                title: "Threshold",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.threshold ?? 10 },
                    set: { vm.activeCompositionBox?.reaction.threshold = $0 }
                ),
                range: 0...100
            )
        }

        if source != .none {
            StageSlider(
                title: "Intensity",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.intensity ?? 70 },
                    set: { vm.activeCompositionBox?.reaction.intensity = $0 }
                ),
                range: 0...100
            )
        }
    }

    // ── Direction cluster (moved wholesale from the editor panel) ──

    private let directionPresets: [(label: String, angle: Double)] = [
        ("→", 0), ("↗", 45), ("↑", 90), ("↖", 135),
        ("←", 180), ("↙", 225), ("↓", 270), ("↘", 315)
    ]

    private var directionControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DIRECTION")
                .font(HueFont.stageTag)
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.6)

            HStack(spacing: 16) {
                // Mini-map
                spatialMiniMap

                Spacer()

                // Angle dial
                motionAngleDial
            }

            // Direction presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<directionPresets.count, id: \.self) { i in
                        let preset = directionPresets[i]
                        let currentAngle = max(0, vm.activeCompositionBox?.motion.motionAngle ?? 0)
                        let isSelected = abs(currentAngle - preset.angle) < 5 || abs(currentAngle - preset.angle - 360) < 5
                        Button {
                            recomputeSpatialPositions(angle: preset.angle)
                            HapticManager.shared.medium()
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(isSelected ? .black : .white.opacity(0.7))
                                .background(
                                    Circle().fill(isSelected ? HuePalette.amber : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    Circle().strokeBorder(isSelected ? .clear : .white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Direction \(Int(preset.angle)) degrees")
                    }
                }
            }
        }
    }

    private var motionAngleDial: some View {
        let currentAngle = max(0, vm.activeCompositionBox?.motion.motionAngle ?? 0)
        let size: CGFloat = 80
        let indicatorRad: CGFloat = (CGFloat(currentAngle) - 90) * .pi / 180

        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.04))
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1.5)
                )

            ForEach(0..<8, id: \.self) { i in
                let tickAngle: CGFloat = CGFloat(i) * 45
                let rad: CGFloat = (tickAngle - 90) * .pi / 180
                let inner: CGFloat = size / 2 - 10
                let outer: CGFloat = size / 2 - 4
                let cosRad: CGFloat = CoreGraphics.cos(rad)
                let sinRad: CGFloat = CoreGraphics.sin(rad)

                Path { path in
                    path.move(to: CGPoint(
                        x: size / 2 + cosRad * inner,
                        y: size / 2 + sinRad * inner
                    ))
                    path.addLine(to: CGPoint(
                        x: size / 2 + cosRad * outer,
                        y: size / 2 + sinRad * outer
                    ))
                }
                .stroke(.white.opacity(0.2), lineWidth: 1.5)
            }

            let indicatorCos: CGFloat = CoreGraphics.cos(indicatorRad)
            let indicatorSin: CGFloat = CoreGraphics.sin(indicatorRad)

            Path { path in
                path.move(to: CGPoint(x: size / 2, y: size / 2))
                path.addLine(to: CGPoint(
                    x: size / 2 + indicatorCos * (size / 2 - 14),
                    y: size / 2 + indicatorSin * (size / 2 - 14)
                ))
            }
            .stroke(
                HuePalette.amber,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )

            Circle()
                .fill(HuePalette.amber)
                .frame(width: 6, height: 6)

            Text("\(Int(currentAngle))°")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .offset(y: size / 2 + 10)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let center = CGPoint(x: size / 2, y: size / 2)
                    let dx = gesture.location.x - center.x
                    let dy = gesture.location.y - center.y
                    var angle = atan2(dy, dx) * 180 / .pi + 90
                    if angle < 0 { angle += 360 }
                    let snapped = (angle / 5).rounded() * 5
                    let final = snapped.truncatingRemainder(dividingBy: 360)

                    let prev = vm.activeCompositionBox?.motion.motionAngle ?? 0
                    let prevSlot = Int(prev / 45)
                    let newSlot = Int(final / 45)
                    if prevSlot != newSlot {
                        HapticManager.shared.selection()
                    }

                    recomputeSpatialPositions(angle: final)
                }
        )
        .animation(.interactiveSpring(response: 0.2), value: currentAngle)
    }

    private var spatialMiniMap: some View {
        let mapSize: CGFloat = 80
        let currentAngle = max(0, vm.activeCompositionBox?.motion.motionAngle ?? 0)

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
            if let config = orchestrator.activeEntertainmentConfig(for: vm.selectedRoom) {
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
            EntertainmentConfigBuilderView { newConfig in
                let bid = vm.selectedRoom?.bridgeID ?? ""
                orchestrator.entertainmentConfigsByBridge[bid] = newConfig
                // The bridge now definitively has an area — availability should
                // flip to .available without another round trip.
                orchestrator.entertainmentConfigsFetchedBridges.insert(bid)
                recomputeSpatialPositions(angle: max(0, vm.activeCompositionBox?.motion.motionAngle ?? 0))
            }
            .environment(orchestrator)
        }
    }

    /// Recompute spatial positions when the angle changes.
    /// Called from Binding setters and chip taps so position recompute happens
    /// exactly once per user edit (CompositionParamBox is @Observable, but an
    /// onChange would also fire on programmatic writes like preset loads).
    private func recomputeSpatialPositions(angle: Double) {
        guard let config = orchestrator.activeEntertainmentConfig(for: vm.selectedRoom),
              let box = vm.activeCompositionBox else { return }
        box.motion.motionAngle = angle
        let newPositions = CompositionEngine.computeSpatialPositionsForEntertainment(
            channels: config.channels,
            motionAngle: angle
        )
        guard !newPositions.isEmpty else { return }
        // Start smooth lerp transition
        box.targetSpatialPositions = newPositions
        box.spatialLerpProgress = 0.0
        box.triggerRESTBurst()
    }
}
