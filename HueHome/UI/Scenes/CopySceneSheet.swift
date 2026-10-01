// CopySceneSheet.swift
// ChromaGlow — Scenes overhaul Phase 5
//
// "Copy to Room…" / "Move to Room…" sheet: pick a target room/zone, see a
// LIVE preview of how the scene's colors remap onto that room's lights
// (with downgrade badges for CT-approximation / brightness-only), name the
// copy, confirm. Cross-bridge targets work — the new scene is built fresh
// against the target bridge's light rids. Never a blind drop: the scene
// drag (Phase 6) lands here pre-targeted.

import SwiftUI

struct CopySceneSheet: View {

    enum Mode {
        case copy, move
        var title: String { self == .copy ? "Copy Scene" : "Move Scene" }
        var verb: String { self == .copy ? "Copy" : "Move" }
    }

    let scene: GlobalSceneItem
    let mode: Mode
    /// Phase 6 drag-drop lands here with the drop target preselected.
    var preselectedTargetID: String? = nil
    /// Fires after a successful copy/move so the host can offer Undo.
    let onComplete: (SceneCopyUndo) -> Void

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var detail: HueSceneDetail?
    @State private var targetRoom: RoomDisplayItem?
    @State private var targetLights: [HueLight] = []
    @State private var remapped: [SceneCopyEngine.RemappedAction] = []
    @State private var name: String = ""
    @State private var isLoadingDetail = true
    @State private var isLoadingPreview = false
    /// Tags each preview load; only the newest may write its results.
    @State private var previewRequestID = 0
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// Copy/move targets. A copy POSTs a new scene on the target's bridge, so
    /// granted (guest) bridges are never offered (copyScene backstops it).
    private var groups: [RoomDisplayItem] {
        (orchestrator.allRooms + orchestrator.allZones)
            .filter { !orchestrator.isGuestGrantedBridge($0.bridgeID) }
    }
    private var multiBridge: Bool {
        Set(groups.compactMap(\.bridgeID)).count > 1
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingDetail {
                    VStack(spacing: 14) {
                        ProgressView().tint(LuminousPalette.ink)
                        Text("Reading scene…")
                            .font(.subheadline)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if detail == nil {
                    errorState
                } else {
                    content
                }
            }
            .background { LuminousAmbience(colors: LuminousScenePalette.colors(for: scene)) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
            }
        }
        .luminousSheet()
        .task { await loadDetail() }
    }

    // ── Content ───────────────────────────────────────────

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    sourceHeader

                    VStack(alignment: .leading, spacing: 10) {
                        LuminousEyebrow(text: mode == .copy ? "Copy to" : "Move to")
                            .padding(.horizontal, 6)
                        roomList
                    }

                    if targetRoom != nil {
                        previewSection
                        nameField
                    }

                    if let errorMessage {
                        LuminousNotice(text: errorMessage, symbol: "exclamationmark.triangle.fill",
                                       tint: LuminousPalette.amber)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            LuminousPrimaryButton(title: "\(mode.verb) to \(targetRoom?.name ?? "Room")",
                                  symbol: mode == .copy ? "doc.on.doc.fill" : "arrow.turn.up.right",
                                  busy: isWorking) {
                Task { await confirm() }
            }
            .disabled(!canConfirm)
        }
        .padding(.horizontal, HueSpacing.screenH)
        .padding(.bottom, 16)
    }

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousSceneArt(colors: LuminousScenePalette.colors(for: scene), isActive: true, lamps: 7, height: 64)
            LuminousScreenTitle(title: mode.title,
                                eyebrow: scene.name,
                                eyebrowSymbol: scene.icon,
                                eyebrowTint: LuminousScenePalette.accent(for: scene),
                                subtitle: scene.isDynamic
                                    ? "A dynamic scene — its palette copies as it is."
                                    : "Each light's color is matched to the lights in the room you pick.")
        }
    }

    private var roomList: some View {
        LuminousGroup {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, room in
                roomChip(room)
                if index < groups.count - 1 { LuminousRowDivider() }
            }
        }
    }

    private func roomChip(_ room: RoomDisplayItem) -> some View {
        let isSelected = targetRoom?.id == room.id
        let isSource = room.id == scene.roomID
        var detail = "\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")"
        if multiBridge, let bridgeID = room.bridgeID, let bridge = orchestrator.bridgeName(for: bridgeID) {
            detail += " · \(bridge)"
        }
        return Button {
            guard targetRoom?.id != room.id else { return }
            targetRoom = room
            errorMessage = nil
            HapticManager.shared.selection()
            Task { await loadPreview(for: room) }
        } label: {
            LuminousChoiceRow(symbol: room.kind == .zone ? "square.stack.3d.up" : archetypeIcon(for: room.archetype),
                              title: room.name,
                              subtitle: detail,
                              tag: isSource ? "Duplicate" : nil,
                              selected: isSelected)
        }
        .buttonStyle(.plain)
    }

    // ── Live remap preview ────────────────────────────────

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "How it lands")
                .padding(.horizontal, 6)

            Group {
                if isLoadingPreview {
                    ProgressView()
                        .tint(LuminousPalette.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else if scene.isDynamic, let palette = detail?.palette?.color, !palette.isEmpty {
                    // Dynamic scenes: the palette is scene-level and copies
                    // verbatim — preview the palette itself.
                    VStack(alignment: .leading, spacing: 8) {
                        LuminousPaletteOrbs(colors: palette.prefix(9).map {
                            previewColor(x: $0.color?.xy?.x, y: $0.color?.xy?.y, mirek: nil)
                        }, count: min(9, max(3, palette.count)), height: 54)
                        Text("The palette copies as it is.")
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                    .padding(14)
                } else if remapped.isEmpty {
                    Text("No lights in this room.")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(remapped.enumerated()), id: \.element.lightID) { index, action in
                            previewRow(action)
                            if index < remapped.count - 1 { LuminousRowDivider(inset: 52) }
                        }
                    }
                }
            }
            .luminousGlass()
        }
    }

    private func previewRow(_ action: SceneCopyEngine.RemappedAction) -> some View {
        let color = previewColor(x: action.x, y: action.y, mirek: action.mirek)
        return HStack(spacing: 12) {
            Circle()
                .fill(action.on
                      ? AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.85), color], center: .topLeading,
                                                     startRadius: 0, endRadius: 16))
                      : AnyShapeStyle(Color.white.opacity(0.06)))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: action.on ? color.opacity(0.7) : .clear, radius: 6)
            Text(action.lightName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LuminousPalette.ink.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !action.on {
                LuminousFactBadge(text: "Off")
            } else if action.downgrade == .ctApproximation {
                LuminousFactBadge(text: "Warmth approx", symbol: "thermometer.medium")
            } else if action.downgrade == .brightnessOnly {
                LuminousFactBadge(text: "Brightness only", symbol: "sun.max")
            }
            if let brightness = action.brightness, action.on {
                Text("\(BrightnessDisplay.percent(brightness))%")
                    .font(LuminousType.value)
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func previewColor(x: Double?, y: Double?, mirek: Int?) -> Color {
        if let x, let y {
            return HueColorUtils.color(fromX: x, y: y, brightness: 100)
        }
        if let mirek {
            return HueColorUtils.color(fromMirek: mirek)
        }
        return .white.opacity(0.7)
    }

    // ── Name + confirm ────────────────────────────────────

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "Name")
                .padding(.horizontal, 6)
            // Bridge caps metadata.name at 32 chars (builder convention).
            LuminousTextField(placeholder: "Scene name", text: $name, symbol: "textformat",
                              tint: LuminousPalette.cyan, limit: 32)
        }
    }

    private var canConfirm: Bool {
        targetRoom != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !isLoadingPreview && !isWorking
    }

    private var errorState: some View {
        LuminousEmptyState(symbol: "exclamationmark.triangle",
                           title: "Couldn't read this scene",
                           message: errorMessage ?? "Couldn't read this scene from the bridge.")
            .padding(HueSpacing.screenH)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    // ── Data flow ─────────────────────────────────────────

    private func loadDetail() async {
        defer { isLoadingDetail = false }
        do {
            detail = try await orchestrator.fetchSceneDetail(scene)
            name = scene.name
            if let preselectedTargetID,
               let preselected = groups.first(where: { $0.id == preselectedTargetID }) {
                targetRoom = preselected
                await loadPreview(for: preselected)
            }
        } catch {
            errorMessage = "Couldn't read the scene — \(error.localizedDescription)"
        }
    }

    private func loadPreview(for room: RoomDisplayItem) async {
        guard let detail else { return }
        // Switching rooms quickly overlaps loads; a slower, older response
        // must not overwrite the newer room's preview (or its error/spinner).
        previewRequestID += 1
        let requestID = previewRequestID
        isLoadingPreview = true
        // Same-room duplicate gets a distinct default name.
        name = room.id == scene.roomID ? "\(scene.name) 2".prefix(32).description : scene.name
        do {
            let lights = try await orchestrator.roomLights(for: room)
            guard requestID == previewRequestID else { return }
            targetLights = lights
            remapped = SceneCopyEngine.remap(detail: detail, targetLights: lights)
        } catch {
            guard requestID == previewRequestID else { return }
            targetLights = []
            remapped = []
            errorMessage = "Couldn't load '\(room.name)' — check the bridge connection"
        }
        isLoadingPreview = false
    }

    private func confirm() async {
        guard let detail, let targetRoom else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let newSceneID = try await orchestrator.copyScene(
                detail: detail,
                source: scene,
                to: targetRoom,
                name: name.trimmingCharacters(in: .whitespaces),
                deleteOriginal: mode == .move
            )
            HapticManager.shared.success()
            onComplete(SceneCopyUndo(
                mode: mode,
                sourceScene: scene,
                sourceDetail: detail,
                newSceneID: newSceneID,
                targetBridgeID: targetRoom.bridgeID ?? scene.bridgeID,
                targetRoomName: targetRoom.name
            ))
            dismiss()
        } catch {
            errorMessage = "\(mode.verb) failed — \(error.localizedDescription)"
            HapticManager.shared.error()
        }
    }
}

// MARK: - SceneCopyUndo

/// Everything needed to undo a copy (delete the new scene) or a move
/// (delete the new scene AND re-POST the retained original verbatim).
struct SceneCopyUndo {
    let mode: CopySceneSheet.Mode
    let sourceScene: GlobalSceneItem
    let sourceDetail: HueSceneDetail
    let newSceneID: String
    let targetBridgeID: String
    let targetRoomName: String
}
