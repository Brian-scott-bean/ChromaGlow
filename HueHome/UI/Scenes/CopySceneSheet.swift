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
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var groups: [RoomDisplayItem] { orchestrator.allRooms + orchestrator.allZones }
    private var multiBridge: Bool {
        Set(groups.compactMap(\.bridgeID)).count > 1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StagePalette.stage.ignoresSafeArea()

                if isLoadingDetail {
                    ProgressView("Reading scene…")
                        .tint(HuePalette.amber)
                        .foregroundStyle(.white.opacity(0.6))
                } else if detail == nil {
                    errorState
                } else {
                    content
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .preferredColorScheme(.dark)
        }
        .task { await loadDetail() }
    }

    // ── Content ───────────────────────────────────────────

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sourceHeader

                    Text(mode == .copy ? "COPY TO" : "MOVE TO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.38))

                    roomList

                    if targetRoom != nil {
                        previewSection
                        nameField
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HuePalette.Noir.destructive)
                    }
                }
                .padding(.top, 8)
            }

            confirmButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(scene.accentColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: scene.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(scene.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if scene.isDynamic {
                    StageBadge(text: "DYNAMIC", style: .amber)
                }
            }
            Spacer()
        }
    }

    private var roomList: some View {
        VStack(spacing: 8) {
            ForEach(groups) { room in
                roomChip(room)
            }
        }
    }

    private func roomChip(_ room: RoomDisplayItem) -> some View {
        let isSelected = targetRoom?.id == room.id
        let isSource = room.id == scene.roomID
        return Button {
            guard targetRoom?.id != room.id else { return }
            targetRoom = room
            errorMessage = nil
            HapticManager.shared.selection()
            Task { await loadPreview(for: room) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: room.kind == .zone ? "square.split.bottomrightquarter" : "lamp.floor")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? HuePalette.amber : StagePalette.muted)
                Text(room.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                if isSource {
                    StageBadge(text: "DUPLICATE", style: .muted)
                }
                if multiBridge, let bridgeID = room.bridgeID {
                    Text(orchestrator.bridgeName(for: bridgeID) ?? "")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StagePalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(room.lightCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StagePalette.muted)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(HuePalette.amber)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? HuePalette.amber.opacity(0.12) : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? HuePalette.amber.opacity(0.5) : StagePalette.line,
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // ── Live remap preview ────────────────────────────────

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.38))

            if isLoadingPreview {
                ProgressView()
                    .tint(HuePalette.amber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if scene.isDynamic, let palette = detail?.palette?.color, !palette.isEmpty {
                // Dynamic scenes: the palette is scene-level and copies
                // verbatim — preview the palette strip itself.
                HStack(spacing: 8) {
                    ForEach(Array(palette.prefix(9).enumerated()), id: \.offset) { _, entry in
                        Circle()
                            .fill(previewColor(x: entry.color?.xy?.x,
                                               y: entry.color?.xy?.y,
                                               mirek: nil))
                            .frame(width: 22, height: 22)
                    }
                    Spacer()
                    StageBadge(text: "PALETTE COPIES AS-IS", style: .muted)
                }
                .padding(.vertical, 4)
            } else if remapped.isEmpty {
                Text("No lights in this room.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(spacing: 6) {
                    ForEach(remapped, id: \.lightID) { action in
                        previewRow(action)
                    }
                }
            }
        }
    }

    private func previewRow(_ action: SceneCopyEngine.RemappedAction) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(action.on
                      ? previewColor(x: action.x, y: action.y, mirek: action.mirek)
                      : Color.white.opacity(0.12))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(StagePalette.line, lineWidth: 1))
            Text(action.lightName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            if !action.on {
                StageBadge(text: "OFF", style: .muted)
            } else if action.downgrade == .ctApproximation {
                StageBadge(text: "WARMTH APPROX", style: .muted)
            } else if action.downgrade == .brightnessOnly {
                StageBadge(text: "BRIGHTNESS ONLY", style: .muted)
            }
            if let brightness = action.brightness, action.on {
                Text("\(Int(brightness))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StagePalette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
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
        VStack(alignment: .leading, spacing: 8) {
            Text("NAME")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.38))
            TextField("Scene name", text: $name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .tint(HuePalette.amber)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                )
                .onChange(of: name) { _, newValue in
                    // Bridge caps metadata.name at 32 chars (builder convention).
                    if newValue.count > 32 { name = String(newValue.prefix(32)) }
                }
        }
    }

    private var canConfirm: Bool {
        targetRoom != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !isLoadingPreview && !isWorking
    }

    private var confirmButton: some View {
        Button {
            Task { await confirm() }
        } label: {
            HStack {
                if isWorking {
                    ProgressView().tint(.black)
                } else {
                    Text("\(mode.verb) to \(targetRoom?.name ?? "Room")")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(canConfirm ? HuePalette.amber : HuePalette.amber.opacity(0.25))
            )
            .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
        .disabled(!canConfirm)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.3))
            Text(errorMessage ?? "Couldn't read this scene from the bridge.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(32)
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
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        // Same-room duplicate gets a distinct default name.
        name = room.id == scene.roomID ? "\(scene.name) 2".prefix(32).description : scene.name
        do {
            targetLights = try await orchestrator.roomLights(for: room)
            remapped = SceneCopyEngine.remap(detail: detail, targetLights: targetLights)
        } catch {
            targetLights = []
            remapped = []
            errorMessage = "Couldn't load '\(room.name)' — check the bridge connection"
        }
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
