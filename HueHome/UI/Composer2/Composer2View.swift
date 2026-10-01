// Composer2View.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The one scrollable creative surface, presented as a full-screen cover from
// Studio's composer deck. Its body holds only the frame: every section is
// its own view. Editors open as sheets over the cover.

import SwiftUI
import MediaAccessibility
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
    @State private var showSaveChoice = false
    @State private var showSaveAsAlert = false
    @State private var showImport = false
    @State private var saveName = ""
    @State private var localNotice: String?
    @State private var gateway: Composer2OrchestratorGateway?
    @State private var micLease = Composer2PreviewMicLease()
    @State private var showDiscardOnClose = false
    /// Increments per room request; a slower, older request never overwrites
    /// a newer one's context.
    @State private var roomRequest = 0

    private let center = Composer2PlaybackCenter.shared

    /// - Parameters:
    ///   - room: the room Studio had selected.
    ///   - composition: open this saved composition instead of the retained
    ///     or default one (the entry card's "Open in Composer").
    ///   - mode: the tab to open on (a saved look opens on Tune).
    init(room: RoomDisplayItem?, composition: Composer2Composition? = nil, mode: Composer2Mode? = nil) {
        self.initialRoom = room
        let center = Composer2PlaybackCenter.shared
        if composition == nil, let retained = center.retainedDocument(for: room?.id), let liveOutput = center.output {
            _document = State(initialValue: retained)
            _output = State(initialValue: liveOutput)
            _feed = State(initialValue: Composer2PreviewFeed(output: liveOutput))
        } else {
            let seed = composition ?? Composer2PresetLibrary.auroraDrift
            let doc = Composer2Document(composition: seed, roomContext: Composer2RoomContext(room: room))
            doc.mode = mode ?? (composition == nil ? .looks : .tune)
            let out = Composer2LiveOutput(composition: seed)
            _document = State(initialValue: doc)
            _output = State(initialValue: out)
            _feed = State(initialValue: Composer2PreviewFeed(output: out))
        }
    }

    var body: some View {
        @Bindable var doc = document
        ZStack {
            Composer2Ambience(colors: Composer2Theme.swatches(of: document.composition, max: 3))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Composer2Header(document: document, center: center, rooms: gateway?.rooms() ?? [],
                                    onSelectRoom: { room in Task { await selectRoom(room) } },
                                    onClose: requestClose)
                    Composer2HeroCard(document: document, center: center, feed: feed, previewOn: previewOn,
                                      onTapLights: { document.activeEditor = .space })
                    Composer2TitleBlock(document: document)
                    Composer2ModeSelector(selection: $doc.mode)
                    Composer2ModeContent(document: document, center: center, onImport: { showImport = true })
                        .id(document.mode)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                    Color.clear.frame(height: HueSpacing.xxl)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.sm)
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
        // The banner sits over the ✕, room picker and undo/redo, so it must
        // not stay: "Saved · …" was still up after a minute (build-60 M-5).
        // Confirmations clear quickly; a microphone problem stays long
        // enough to read (it asks the user to do something).
        .task(id: localNotice) {
            guard let shown = localNotice else { return }
            let isProblem = shown == Composer2Copy.micDenied || shown == Composer2Copy.micCaptureFailed
            try? await Task.sleep(for: .seconds(isProblem ? 8 : (shown == Composer2Copy.applied ? 5 : 3)))
            guard !Task.isCancelled, localNotice == shown else { return }
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = nil }
        }
        .sheet(item: $doc.activeEditor) { editor in
            Composer2EditorSheet(document: document, editor: editor, feed: feed)
                .environment(orchestrator)
        }
        .sheet(isPresented: $showImport) {
            Composer2ImportSheet(document: document)
        }
        .confirmationDialog("Save composition", isPresented: $showSaveChoice, titleVisibility: .visible) {
            Button(Composer2Copy.saveOverwrite) { saveOverwrite() }
            Button(Composer2Copy.saveAsNew) { promptSaveAsNew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save replaces \"\(document.composition.name)\". Save as new keeps both.")
        }
        .alert("Save as new", isPresented: $showSaveAsAlert) {
            TextField("Name", text: $saveName)
            Button("Save") { saveAsNew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved looks live under Yours in the Composer, and can be played from any room.")
        }
        .confirmationDialog("Discard your changes?", isPresented: $showDiscardOnClose, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button(Composer2Copy.saveAsNew) { promptSaveAsNew() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("\"\(document.composition.name)\" has changes you haven't saved.")
        }
        .confirmationDialog("Replace your changes?", isPresented: Binding(
            get: { document.pendingReplacement != nil },
            set: { if !$0 { document.pendingReplacement = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) { document.confirmPendingReplacement() }
            Button("Keep editing", role: .cancel) { document.pendingReplacement = nil }
        } message: {
            Text("\"\(document.composition.name)\" has changes you haven't saved. Opening another look replaces them.")
        }
        .alert(EntertainmentConsentCopy.takeoverTitle, isPresented: Binding(
            get: { center.takeoverPending },
            set: { if !$0 { center.answerTakeover(false) } })) {
            Button(EntertainmentConsentCopy.keepExisting, role: .cancel) { center.answerTakeover(false) }
            Button(EntertainmentConsentCopy.takeOver) {
                HapticManager.shared.light()
                center.answerTakeover(true)
            }
        }
        .task { await prepare() }
        .onAppear { center.attachScreen() }
        // The preview plays what the document holds, always — edits, mood
        // changes and imports included. It used to follow the document only
        // while a live session was bound, so the hero kept drawing the look
        // the screen opened with.
        .onChange(of: document.composition, initial: true) { _, composition in
            if output.composition != composition { output.composition = composition }
        }
        .onReceive(NotificationCenter.default.publisher(for: kMADimFlashingLightsChangedNotification as NSNotification.Name)) { _ in
            output.eventCap = Composer2LiveOutput.accessibilityEventCap()
        }
        .onChange(of: previewOn) { _, _ in updateMicLease() }
        .onChange(of: document.usesAudio) { _, _ in updateMicLease() }
        .onChange(of: center.session) { _, _ in updateMicLease() }
        .onReceive(NotificationCenter.default.publisher(for: .compositionMicPermissionDenied)) { _ in
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = Composer2Copy.micDenied }
        }
        .onReceive(NotificationCenter.default.publisher(for: .compositionMicCaptureFailed)) { _ in
            // Permission is fine but the microphone would not start (another
            // app holding it, a route change mid-start) — say so, not "denied".
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = Composer2Copy.micCaptureFailed }
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
        roomRequest += 1
        let request = roomRequest
        var context = Composer2RoomContext(room: room)
        context.isDemo = gw.isDemo()
        if let room {
            await gw.warm(room: room)
            // A newer room request superseded this one while it warmed.
            guard request == roomRequest else { return }
            let lights = gw.lightItems(room: room)
            context.lights = lights
            if isLiveHere, let live = center.session, live.roomID == room.id, !document.roomContext.layout.isEmpty {
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
                context.connectionText = Composer2Copy.connectionText(availability)
            case .demo: context.connectionText = Composer2Copy.demoHome
            case .noBridge: context.connectionText = "Bridge unavailable"
            case .noRoom: context.connectionText = ""
            }
        }
        document.roomContext = context
        if !(isLiveHere && center.session?.roomID == room?.id) {
            // Not this screen's live session: whatever geometry a past live
            // run installed (an ended session keeps it) must give way to the
            // room the screen now shows.
            output.releaseLiveGeometry()
            output.setPreviewGeometry(context.layout.geometry)
            output.layoutLightIDs = context.layout.lightIDs
        }
    }

    /// The lights are playing THIS document. `center.isLive` alone is true
    /// for a look applied to another room from the Studio card, and the
    /// screen used to take that session for its own (Stop stopped it,
    /// Apply claimed it, the hero said LIVE).
    private var isLiveHere: Bool { center.isPlaying(document: document) }

    private func selectRoom(_ room: RoomDisplayItem) async {
        guard let gw = gateway else { return }
        // Only this screen's own session follows the room picker; a start
        // still in flight is stopped too, so it can never land in the old
        // room while the screen shows the new one.
        if (isLiveHere && center.session?.roomID != room.id) || (center.isBusy && center.document === document) {
            await center.stop(gateway: gw)
        }
        document.selectedSlots = []
        await refreshRoomContext(room, gateway: gw)
        HapticManager.shared.selection()
    }

    private func leave() {
        micLease.release()
        center.detachScreen()
        if let gw = gateway { center.endAudition(gateway: gw) }
    }

    private func updateMicLease() {
        let needed = previewOn && document.usesAudio && !isLiveHere
        micLease.update(needed: needed)
    }

    private func requestClose() {
        if document.isDirty {
            HapticManager.shared.warning()
            showDiscardOnClose = true
        } else {
            dismiss()
        }
    }

    // MARK: Actions

    private func toggleLive() {
        guard let gw = gateway, !center.isBusy else { return }
        if isLiveHere {
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
        guard let gw = gateway, !center.isBusy else { return }
        HapticManager.shared.medium()
        if isLiveHere {
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
        HapticManager.shared.light()
        if document.isSourceUserOwned {
            showSaveChoice = true
        } else {
            promptSaveAsNew()
        }
    }

    private func promptSaveAsNew() {
        saveName = document.composition.name
        showSaveAsAlert = true
    }

    private func saveOverwrite() {
        let saved = Composer2Store.shared.save(document.composition)
        document.adoptSaved(saved)
        HapticManager.shared.success()
        withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = "\(Composer2Copy.saved) · \(saved.name)" }
    }

    private func saveAsNew() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        var composition = document.composition.duplicated(name: trimmed.isEmpty ? document.composition.name : trimmed, at: Date())
        composition.target = document.composition.target
        let saved = Composer2Store.shared.save(composition)
        document.adoptSaved(saved)
        HapticManager.shared.success()
        withAnimation(reduceMotion ? nil : HueAnimation.fast) { localNotice = "\(Composer2Copy.saved) · \(saved.name)" }
    }
}

// MARK: - Mode content

struct Composer2ModeContent: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    let onImport: () -> Void

    var body: some View {
        switch document.mode {
        case .looks:
            Composer2LibraryView(document: document, center: center, onImport: onImport)
        case .tune:
            Composer2TuneView(document: document)
        case .layers:
            Composer2LayersView(document: document)
        }
    }
}

// MARK: - Legacy import sheet

struct Composer2ImportSheet: View {
    let document: Composer2Document
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [CompositionPreset] = []
    @State private var pendingImport: CompositionPreset?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Composer2Copy.importLegacyTitle)
                        .font(HueFont.displaySmall)
                        .foregroundStyle(Composer2Theme.ink)
                    Text(Composer2Copy.importLegacyHint)
                        .font(HueFont.caption)
                        .foregroundStyle(Composer2Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .font(HueFont.bodyMedium)
                    .foregroundStyle(Composer2Theme.cyan)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, HueSpacing.lg)
            .padding(.bottom, HueSpacing.sm)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if presets.isEmpty {
                        Text(Composer2Copy.importNothing)
                            .font(HueFont.body)
                            .foregroundStyle(Composer2Theme.muted)
                            .padding(.top, HueSpacing.xl)
                    }
                    ForEach(presets) { preset in
                        Button {
                            HapticManager.shared.medium()
                            if document.isDirty {
                                pendingImport = preset
                            } else {
                                document.importLegacy(preset)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Composer2Theme.cyan)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Composer2Theme.cyan.opacity(0.12)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name).font(HueFont.bodyMedium).foregroundStyle(Composer2Theme.ink)
                                    Text(preset.category.rawValue).font(HueFont.stageStatus).foregroundStyle(Composer2Theme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "square.and.arrow.down")
                                    .foregroundStyle(Composer2Theme.muted)
                            }
                            .padding(12)
                            .composer2Glass()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Import \(preset.name)")
                    }
                    Color.clear.frame(height: HueSpacing.xl)
                }
                .padding(.horizontal, HueSpacing.screenH)
            }
        }
        .background(Composer2Theme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Composer2Theme.background)
        .preferredColorScheme(.dark)
        .confirmationDialog("Replace your changes?", isPresented: Binding(
            get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Import and replace", role: .destructive) {
                if let preset = pendingImport { document.importLegacy(preset) }
                pendingImport = nil
                dismiss()
            }
            Button("Keep editing", role: .cancel) { pendingImport = nil }
        } message: {
            Text("\"\(document.composition.name)\" has changes you haven't saved.")
        }
        .task {
            presets = CompositionStore.readPresets(from: CompositionStore.defaultFileURL).presets
        }
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
