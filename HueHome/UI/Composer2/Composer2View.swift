// Composer2View.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The one scrollable creative surface, presented as a full-screen cover from
// Studio's composer deck. Its body holds only the frame: every section is
// its own view. Editors open as sheets over the cover.

import SwiftUI
import QuartzCore

struct Composer2View: View {
    let initialRoom: RoomDisplayItem?

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var document: Composer2Document
    @State private var output: Composer2LiveOutput
    @State private var feed: Composer2PreviewFeed
    @State private var previewOn = true
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @State private var localNotice: String?
    @State private var gateway: Composer2OrchestratorGateway?
    @State private var micLease = Composer2PreviewMicLease()

    private let center = Composer2PlaybackCenter.shared

    init(room: RoomDisplayItem?) {
        self.initialRoom = room
        let center = Composer2PlaybackCenter.shared
        if let retained = center.retainedDocument(for: room?.id), let liveOutput = center.output {
            _document = State(initialValue: retained)
            _output = State(initialValue: liveOutput)
            _feed = State(initialValue: Composer2PreviewFeed(output: liveOutput))
        } else {
            let composition = Composer2PresetLibrary.auroraDrift
            let doc = Composer2Document(composition: composition,
                                        roomContext: Composer2RoomContext(room: room))
            let out = Composer2LiveOutput(composition: composition)
            _document = State(initialValue: doc)
            _output = State(initialValue: out)
            _feed = State(initialValue: Composer2PreviewFeed(output: out))
        }
    }

    var body: some View {
        @Bindable var doc = document
        ZStack {
            Composer2Theme.backgroundGradient.ignoresSafeArea()
            Composer2BackgroundWashes()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: HueSpacing.lg) {
                    Composer2Header(document: document, center: center, rooms: gateway?.rooms() ?? [],
                                    onSelectRoom: { room in Task { await selectRoom(room) } },
                                    onClose: { dismiss() })
                    Composer2HeroCard(document: document, center: center, feed: feed, previewOn: previewOn,
                                      onTapLights: { document.activeEditor = .space })
                    Composer2TitleBlock(document: document)
                    Composer2ModeSelector(selection: $doc.mode)
                    Composer2ModeContent(document: document, feed: feed)
                    Color.clear.frame(height: HueSpacing.xxl)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.md)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer2PerformanceBar(document: document, center: center, previewOn: $previewOn,
                                    onLive: toggleLive, onSave: promptSave, onApply: apply,
                                    onDismissNotice: { center.clearNotice(); localNotice = nil })
        }
        .overlay(alignment: .top) {
            if let localNotice {
                Composer2NoticeBanner(text: localNotice) { self.localNotice = nil }
                    .padding(.top, 8)
                    .padding(.horizontal, HueSpacing.screenH)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $doc.activeEditor) { editor in
            Composer2EditorSheet(document: document, editor: editor, feed: feed)
                .environment(orchestrator)
        }
        .alert("Save composition", isPresented: $showSaveAlert) {
            TextField("Name", text: $saveName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved compositions appear in Quick mode and stay separate from your Composer cards.")
        }
        .task { await prepare() }
        .onChange(of: previewOn) { _, _ in updateMicLease() }
        .onChange(of: document.usesAudio) { _, _ in updateMicLease() }
        .onChange(of: center.session) { _, _ in updateMicLease() }
        .onReceive(NotificationCenter.default.publisher(for: .compositionMicPermissionDenied)) { _ in
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = Composer2Copy.micDenied }
        }
        .onDisappear { leave() }
        .environment(orchestrator)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }

    // MARK: Lifecycle

    private func prepare() async {
        let gw = Composer2OrchestratorGateway(orchestrator: orchestrator)
        gateway = gw
        let room = document.roomContext.room ?? initialRoom ?? gw.rooms().first
        await refreshRoomContext(room, gateway: gw)
        updateMicLease()
    }

    private func refreshRoomContext(_ room: RoomDisplayItem?, gateway gw: Composer2OrchestratorGateway) async {
        var context = Composer2RoomContext(room: room)
        context.isDemo = gw.isDemo()
        if let room {
            await gw.warm(room: room)
            let lights = gw.lightItems(room: room)
            context.lights = lights
            if let live = center.session, live.roomID == room.id, !document.roomContext.layout.isEmpty {
                context.layout = document.roomContext.layout
            } else if gw.gate(for: room) == .ready, let streaming = gw.streamingLayout(room: room, lights: lights) {
                context.layout = streaming
            } else if gw.isDemo() {
                context.layout = Composer2SlotLayout.estimated(lights: lights)
            } else {
                context.layout = gw.roomLayout(room: room, lights: lights)
            }
            switch gw.gate(for: room) {
            case .ready:
                let availability = gw.streamAvailability(for: room)
                context.connectionText = availability.prefer ? "Bridge · streaming ready" : "Bridge · Room mode"
            case .demo: context.connectionText = Composer2Copy.demoHome
            case .noBridge: context.connectionText = "Bridge unavailable"
            case .noRoom: context.connectionText = ""
            }
        }
        document.roomContext = context
        if !center.isLive || center.session?.roomID != room?.id {
            output.setPreviewGeometry(context.layout.geometry)
            output.layoutLightIDs = context.layout.lightIDs
        }
    }

    private func selectRoom(_ room: RoomDisplayItem) async {
        guard let gw = gateway else { return }
        if center.isLive, center.session?.roomID != room.id {
            await center.stop(gateway: gw)
        }
        document.selectedSlots = []
        await refreshRoomContext(room, gateway: gw)
        HapticManager.shared.selection()
    }

    private func leave() {
        micLease.release()
        if let gw = gateway { center.endAudition(gateway: gw) }
    }

    private func updateMicLease() {
        let needed = previewOn && document.usesAudio && !center.isLive
        micLease.update(needed: needed)
    }

    // MARK: Actions

    private func toggleLive() {
        guard let gw = gateway else { return }
        if center.isLive {
            HapticManager.shared.medium()
            Task { await center.stop(gateway: gw) }
        } else {
            HapticManager.shared.success()
            previewOn = true
            Task {
                let status = await center.start(document: document, output: output, gateway: gw, audition: true)
                if case .failed = status { HapticManager.shared.warning() }
            }
        }
    }

    private func apply() {
        guard let gw = gateway else { return }
        HapticManager.shared.medium()
        if center.isLive {
            center.promoteToApplied()
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = Composer2Copy.applied }
        } else {
            previewOn = true
            Task {
                let status = await center.start(document: document, output: output, gateway: gw, audition: false)
                if status == .live {
                    withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = Composer2Copy.applied }
                }
            }
        }
    }

    private func promptSave() {
        saveName = document.composition.name
        showSaveAlert = true
        HapticManager.shared.light()
    }

    private func save() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        var composition = document.composition
        if !trimmed.isEmpty { composition.name = trimmed }
        let saved = Composer2Store.shared.save(composition)
        document.load(saved, asSource: true)
        HapticManager.shared.success()
        withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = "\(Composer2Copy.saved) · \(saved.name)" }
    }
}

// MARK: - Mode content

private struct Composer2ModeContent: View {
    let document: Composer2Document
    let feed: Composer2PreviewFeed

    var body: some View {
        switch document.mode {
        case .quick:
            Composer2QuickPanel(document: document)
        case .customize:
            Composer2CustomizeGrid(document: document)
        case .advanced:
            Composer2AdvancedPanel(document: document)
        case .expert:
            Composer2ExpertStack(document: document)
        }
    }
}

// MARK: - Background washes

private struct Composer2BackgroundWashes: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Composer2Theme.cyan.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: proxy.size.width * 0.7))
                    .frame(width: proxy.size.width * 1.4)
                    .position(x: proxy.size.width * 0.15, y: proxy.size.height * 0.1)
                Circle()
                    .fill(RadialGradient(colors: [Composer2Theme.violet.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: proxy.size.width * 0.7))
                    .frame(width: proxy.size.width * 1.4)
                    .position(x: proxy.size.width * 0.9, y: proxy.size.height * 0.75)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Notice banner

struct Composer2NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Composer2Theme.cyan)
            Text(text)
                .font(HueFont.captionMedium)
                .foregroundStyle(Composer2Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Composer2Theme.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .composer2Glass(cornerRadius: 14, raised: true)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

// MARK: - Preview microphone lease

/// Holds the preview's audio demand only while an audio-reactive layer is
/// actually previewing. Idempotent; released on disappear.
@MainActor
final class Composer2PreviewMicLease {
    private var held = false

    func update(needed: Bool) {
        guard needed != held else { return }
        held = needed
        Task { await AudioAnalysisEngine.shared.setDemand(.composer2Preview, active: needed) }
    }

    func release() {
        update(needed: false)
    }
}
