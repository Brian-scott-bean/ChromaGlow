// CompositionEditorPanel.swift
// CastChroma — Composer editor (extracted from StudioView in Round 4, R4-1).
//
// The four-layer live mixer for the running composition: Palette / Motion /
// Envelope / React tabs, the beat quick-toggle, and the dynamic-scene export.
// Pure move — every member is byte-identical to its StudioView original;
// only access levels and parameter plumbing changed.
//
// Ownership:
//   - Panel owns transient editor state (hue-pad drag, prompts, sheets).
//   - StudioView keeps @State for the pieces it must outlive the panel:
//     activeCompositionTab / activeHarmonyRule / editingSwatch (bindings),
//     because the harmony-restore onChange chain and tab persistence run at
//     StudioView scope even while the mixer tray is closed.

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
        case .envelope: return "Envelope"
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
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let vm: StudioViewModel
    @Binding var activeCompositionTab: CompositionLayerTab
    @Binding var activeHarmonyRule: HarmonyRule
    @Binding var editingSwatch: SwatchEditItem?

    // Round 3 (E): "Save as Hue dynamic scene" name prompt.
    @State private var showDynamicScenePrompt = false
    @State private var dynamicSceneName = ""
    @State private var isHuePadDragging = false
    @State private var huePadLiveHue: Double = 0
    @State private var huePadLiveSaturation: Double = 1
    @State private var lastHuePadHapticAt: CFAbsoluteTime = 0
    @State private var showEntertainmentBuilder = false

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
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)

            Group {
                switch activeCompositionTab {
                case .palette: compositionPaletteControls
                case .motion: compositionMotionControls
                case .envelope: compositionEnvelopeControls
                case .reaction: compositionReactionControls
                }
            }
            .id(activeCompositionTab)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .animation(HueAnimation.fast, value: activeCompositionTab)
        }
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
                .font(.system(size: 10, weight: .bold))
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

    private func reactionTargetToggleBinding(_ target: ReactionConfig.Target) -> Binding<Bool> {
        Binding(
            get: { vm.activeCompositionBox?.reaction.targets.contains(target) ?? false },
            set: { on in
                guard let box = vm.activeCompositionBox else { return }
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

    /// Harmony chips visible only in solid/gradient mode AND when room has color lights.
    private var showHarmonyControls: Bool {
        let mode = vm.activeCompositionBox?.palette.mode ?? .gradient
        return (mode == .solid || mode == .gradient) && vm.roomHasColorLights
    }

    /// Rules exposed in the chip row — excludes 4-color rules until color4 is added.
    private var filteredHarmonyRules: [HarmonyRule] {
        [.none, .complementary, .triadic, .analogous, .splitComplementary, .monochromatic]
    }

    private var compositionPaletteControls: some View {
        StageCard(icon: "paintpalette.fill", title: "Color", subtitle: "Palette every light reads before motion and envelope.") {
            VStack(spacing: HueSpacing.sm) {

            Picker("Mode", selection: Binding(
                get: { vm.activeCompositionBox?.palette.mode ?? .gradient },
                set: { newMode in
                    vm.activeCompositionBox?.palette.mode = newMode
                    // Auto-dismiss harmony when switching to a mode that ignores color fields
                    if newMode != .solid && newMode != .gradient && activeHarmonyRule != .none {
                        activeHarmonyRule = .none
                    }
                }
            )) {
                ForEach(PaletteConfig.Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            hueSaturationPad

            harmonyChipRow

            if (vm.activeCompositionBox?.palette.mode ?? .gradient) == .spectrum {
                StageSlider(
                    title: "Hue Shift",
                    value: Binding(
                        get: { vm.activeCompositionBox?.palette.hueShift ?? 0 },
                        set: { vm.activeCompositionBox?.palette.hueShift = $0 }
                    ),
                    range: -180...180
                )
            }

            Toggle("Randomize", isOn: Binding(
                get: { vm.activeCompositionBox?.palette.randomize ?? false },
                set: { vm.activeCompositionBox?.palette.randomize = $0 }
            ))
            .tint(HuePalette.amber)

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

    // ──────────────────────────────────────────────
    // MARK: - Harmony Chip Row
    // ──────────────────────────────────────────────

    @ViewBuilder
    private var harmonyChipRow: some View {
        if showHarmonyControls {
            VStack(alignment: .leading, spacing: 8) {
                Text("HARMONY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .tracking(0.6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filteredHarmonyRules) { rule in
                            harmonyChipButton(rule)
                        }
                    }
                }

                if activeHarmonyRule != .none {
                    harmonySwatchPreview
                        .popover(item: $editingSwatch) { item in
                            swatchEditPopover(index: item.id)
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

    private func harmonyChipButton(_ rule: HarmonyRule) -> some View {
        let isSelected = activeHarmonyRule == rule
        return Button {
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

    private var harmonySwatchPreview: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                let color = harmonySwatchColor(at: index)
                let isEditing = editingSwatch?.id == index
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.white.opacity(isEditing ? 0.9 : 0.5), lineWidth: isEditing ? 2.5 : 1.5))
                    .shadow(color: color.opacity(isEditing ? 0.7 : 0.4), radius: isEditing ? 8 : 4)
                    .onTapGesture {
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

    private func swatchEditPopover(index: Int) -> some View {
        VStack(spacing: 12) {
            Text("Color \(index + 1)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            ColorWheelView(
                hue: swatchHueBinding(index),
                saturation: swatchSatBinding(index)
            ) { h, s in
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

    private var hueSaturationPad: some View {
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
        let currentHue: Double = canonicalHSB.h
        let currentSat: Double = canonicalHSB.s
        let displayHue = isHuePadDragging ? huePadLiveHue : currentHue
        let displaySat = isHuePadDragging ? huePadLiveSaturation : currentSat
        let thumbColor = Color(hue: displayHue, saturation: displaySat, brightness: 1.0)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hue + Saturation")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Circle()
                    .fill(thumbColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                Text("\(Int((displayHue * 360).rounded()))° • \(Int((displaySat * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let h = max(1, geo.size.height)
                let thumbX = CGFloat(displayHue) * w
                let thumbY = (1.0 - CGFloat(displaySat)) * h

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .red
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white, .white.opacity(0.0)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)

                    Circle()
                        .fill(thumbColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                        .position(x: thumbX, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let clampedX = min(max(gesture.location.x, 0), w)
                            let clampedY = min(max(gesture.location.y, 0), h)
                            let hue = Double(clampedX / w)
                            let sat = Double(1.0 - (clampedY / h))
                            let clampedSat = min(1.0, max(0.0, sat))
                            isHuePadDragging = true
                            vm.activeCompositionBox?.isColorPadInteracting = true
                            vm.activeCompositionBox?.triggerRESTBurst()
                            huePadLiveHue = hue
                            huePadLiveSaturation = clampedSat
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - lastHuePadHapticAt >= 0.08 {
                                HapticManager.shared.selection()
                                lastHuePadHapticAt = now
                            }
                            let xy = HueColorUtils.xyFrom(hue: hue, saturation: clampedSat, brightness: 1.0)
                            let clampedXY = HueColorUtils.clampXYToGamut(
                                x: xy.x,
                                y: xy.y,
                                gamut: vm.activeCompositionGamut
                            )
                            let clampedHSB = HueColorUtils.hsb(
                                fromX: clampedXY.x,
                                y: clampedXY.y,
                                brightness: 100
                            )
                            huePadLiveHue = clampedHSB.h
                            huePadLiveSaturation = clampedHSB.s
                            if activeHarmonyRule != .none {
                                let paletteColors = HarmonyEngine.palette(
                                    rule: activeHarmonyRule,
                                    rootHue: clampedHSB.h,
                                    saturation: clampedHSB.s,
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
                                vm.activeCompositionBox?.palette.color1 = CodableColor(x: clampedXY.x, y: clampedXY.y)
                            }
                            vm.activeCompositionBox?.palette.saturation = clampedHSB.s * 100
                        }
                        .onEnded { _ in
                            isHuePadDragging = false
                            vm.activeCompositionBox?.isColorPadInteracting = false
                            vm.activeCompositionBox?.triggerRESTBurst()
                            lastHuePadHapticAt = 0
                            HapticManager.shared.selection()
                        }
                )
            }
            .frame(height: isCompactStudio ? 118 : 156)
        }
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
        "beat": "Beat", "onset": "Onset",
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

    /// Direction is relevant for all patterns except scatter.
    private var motionPatternIsSpatial: Bool {
        let pattern = vm.activeCompositionBox?.motion.pattern ?? .cascade
        // Scatter and twinkle are non-directional (per-light hashing).
        return pattern != .scatter && pattern != .twinkle
    }

    private var compositionMotionControls: some View {
        StageCard(icon: "wind", title: "Motion", subtitle: "How color travels across lights over time.") {
            VStack(spacing: HueSpacing.sm) {

            PatternStripView(
                pattern: vm.activeCompositionBox?.motion.pattern ?? .cascade,
                animated: vm.currentRoomEffect != nil
            )

            // One-tap pattern pills: every pattern visible at once (was a
            // 2-tap menu). Icons give each motion a recognizable signature.
            VStack(alignment: .leading, spacing: 4) {
                Text("Pattern")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: MotionConfig.Pattern.allCases.map { pattern in
                        ChipPickerRow<MotionConfig.Pattern>.Item(
                            value: pattern,
                            label: pattern.rawValue
                                .replacingOccurrences(of: "_", with: " ").capitalized,
                            icon: Self.patternIcons[pattern.rawValue])
                    },
                    selection: Binding(
                        get: { vm.activeCompositionBox?.motion.pattern ?? .cascade },
                        set: { vm.activeCompositionBox?.motion.pattern = $0 }
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Direction Control ──
            if motionPatternIsSpatial {
                if orchestrator.activeEntertainmentConfig(for: vm.selectedRoom) != nil {
                    directionControl
                } else {
                    entertainmentAreaPrompt
                }
            }

            StageSlider(
                title: "Speed",
                value: Binding(
                    get: { vm.activeCompositionBox?.motion.speed ?? 40 },
                    set: { vm.activeCompositionBox?.motion.speed = $0 }
                ),
                range: 0...100
            )

            StageSlider(
                title: "Spread",
                value: Binding(
                    get: { vm.activeCompositionBox?.motion.spread ?? 70 },
                    set: { vm.activeCompositionBox?.motion.spread = $0 }
                ),
                range: 0...100
            )

            Toggle("Forward", isOn: Binding(
                get: { vm.activeCompositionBox?.motion.forward ?? true },
                set: { vm.activeCompositionBox?.motion.forward = $0 }
            ))
            .tint(HuePalette.amber)

            StageSlider(
                title: "Offset",
                value: Binding(
                    get: { vm.activeCompositionBox?.motion.offset ?? 50 },
                    set: { vm.activeCompositionBox?.motion.offset = $0 }
                ),
                range: 0...100
            )

            Toggle("Mirror", isOn: Binding(
                get: { vm.activeCompositionBox?.motion.mirror ?? false },
                set: { vm.activeCompositionBox?.motion.mirror = $0 }
            ))
            .tint(HuePalette.amber)
        }
            }
    }

    // ──────────────────────────────────────────────
    // MARK: - Direction Control
    // ──────────────────────────────────────────────

    private let directionPresets: [(label: String, angle: Double)] = [
        ("→", 0), ("↗", 45), ("↑", 90), ("↖", 135),
        ("←", 180), ("↙", 225), ("↓", 270), ("↘", 315)
    ]

    private var directionControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DIRECTION")
                .font(.system(size: 10, weight: .bold))
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

    // ──────────────────────────────────────────────
    // MARK: - Angle Dial
    // ──────────────────────────────────────────────

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

    // ──────────────────────────────────────────────
    // MARK: - Spatial Mini-Map
    // ──────────────────────────────────────────────

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
                    let dotColor = harmonySwatchColor(at: i % 3)

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

    // ──────────────────────────────────────────────
    // MARK: - Entertainment Area Prompt
    // ──────────────────────────────────────────────

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
                recomputeSpatialPositions(angle: max(0, vm.activeCompositionBox?.motion.motionAngle ?? 0))
            }
            .environment(orchestrator)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Spatial Position Recomputation
    // ──────────────────────────────────────────────

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

    private var compositionEnvelopeControls: some View {
        StageCard(icon: "waveform.path.ecg", title: "Envelope", subtitle: "Brightness shape over time.") {
            VStack(spacing: HueSpacing.sm) {

            VStack(alignment: .leading, spacing: 4) {
                Text("Shape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: EnvelopeConfig.Shape.allCases.map { shape in
                        ChipPickerRow<EnvelopeConfig.Shape>.Item(
                            value: shape, label: shape.rawValue.capitalized)
                    },
                    selection: Binding(
                        get: { vm.activeCompositionBox?.envelope.shape ?? .breathe },
                        set: { vm.activeCompositionBox?.envelope.shape = $0 }
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StageSlider(
                title: "BPM",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.bpm ?? 60 },
                    set: { vm.activeCompositionBox?.envelope.bpm = $0 }
                ),
                range: 20...240
            )

            StageSlider(
                title: "Depth",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.depth ?? 50 },
                    set: { vm.activeCompositionBox?.envelope.depth = $0 }
                ),
                range: 0...100
            )

            // Shape-specific controls (the engine has always consumed these;
            // the sliders were simply missing from the editor).
            if (vm.activeCompositionBox?.envelope.shape ?? .breathe) == .swell {
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
            if (vm.activeCompositionBox?.envelope.shape ?? .breathe) == .pulse {
                StageSlider(
                    title: "Duty Cycle",
                    value: Binding(
                        get: { vm.activeCompositionBox?.envelope.dutyCycle ?? 50 },
                        set: { vm.activeCompositionBox?.envelope.dutyCycle = $0 }
                    ),
                    range: 10...90
                )
            }

            StageSlider(
                title: "Min Brightness",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.minBrightness ?? 10 },
                    set: { vm.activeCompositionBox?.envelope.minBrightness = $0 }
                ),
                range: 0...50
            )
            StageSlider(
                title: "Max Brightness",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.maxBrightness ?? 100 },
                    set: { vm.activeCompositionBox?.envelope.maxBrightness = $0 }
                ),
                range: 50...100
            )
        }
            }
    }

    private var compositionReactionControls: some View {
        StageCard(icon: "bolt.fill", title: "React", subtitle: "Audio and responsiveness layered on top.") {
            VStack(spacing: HueSpacing.sm) {

            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                ChipPickerRow(
                    items: ReactionConfig.Source.allCases.map { source in
                        ChipPickerRow<ReactionConfig.Source>.Item(
                            value: source,
                            label: Self.sourceLabels[source.rawValue]
                                ?? source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                            icon: Self.sourceIcons[source.rawValue])
                    },
                    selection: Binding(
                        get: { vm.activeCompositionBox?.reaction.source ?? .none },
                        set: { vm.activeCompositionBox?.reaction.source = $0 }
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if (vm.activeCompositionBox?.reaction.source ?? .none) != .none {
                VStack(alignment: .leading, spacing: 8) {
                    compositionSectionHeader("Targets", subtitle: "Which outputs the reaction modulates.")
                    ForEach(ReactionConfig.Target.allCases, id: \.self) { target in
                        Toggle(reactionTargetLabel(target), isOn: reactionTargetToggleBinding(target))
                            .tint(HuePalette.amber)
                    }
                }
            }

            reactionBeatControls
                .id("reactionBeatControls")   // ScrollViewReader auto-anchor target

            StageSlider(
                title: "Sensitivity",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.sensitivity ?? 70 },
                    set: { vm.activeCompositionBox?.reaction.sensitivity = $0 }
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
