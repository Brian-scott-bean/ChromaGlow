// StudioView.swift
// CastChroma — v0.17.0 Studio + Composer Deck 3
//
// Layout: Three fixed zones (no root scroll)
//   Zone A: Rolodex room/zone selector (~126pt: a 26pt legend row over a 96pt
//           two-axis wheel; hidden while a full-screen entertainment effect runs)
//   Zone B: 2-column living card grid (paged: Effects / Live / Composer decks)
//   Zone C: Mixer Tray (springs from bottom when an effect runs)
//
// Performance contract:
//   - Canvas views isolated: receive value types only
//   - Sliders: local @State, commit on drag end
//   - Cards: receive Bool isRunning, never the ViewModel
//   - All colors/spacing/animation via HueTokens

import SwiftUI
import CoreGraphics

// MARK: - StudioView

struct StudioView: View {
    /// The engine a saved preset asks for. `auto` (a nil `preferredTransport`)
    /// lets the tier decide — which is what every preset did before this menu
    /// existed, so nil stays the default and needs no decode migration.
    private enum TransportPreference: String, CaseIterable, Identifiable {
        case auto
        case entertainmentArea
        case roomOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto:              return "Auto (match the scene)"
            case .entertainmentArea: return "Entertainment Area — streamed"
            case .roomOnly:          return "Room Only — REST"
            }
        }

        var presetValue: CompositionPreferredTransport? {
            switch self {
            case .auto:              return nil
            case .entertainmentArea: return .entertainmentArea
            case .roomOnly:          return .roomOnly
            }
        }
    }

    private enum CompositionSaveTransportOption: String, CaseIterable, Identifiable {
        case entertainmentArea
        case roomOnly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .entertainmentArea: return "Entertainment Area"
            case .roomOnly: return "Room Only"
            }
        }

        var subtitle: String {
            switch self {
            case .entertainmentArea: return "Streaming"
            case .roomOnly: return "REST"
            }
        }

        var presetValue: CompositionPreferredTransport {
            switch self {
            case .entertainmentArea: return .entertainmentArea
            case .roomOnly: return .roomOnly
            }
        }

        /// Short titles for segmented controls on narrow widths.
        var segmentTitle: String {
            switch self {
            case .entertainmentArea: return "Streaming"
            case .roomOnly: return "REST"
            }
        }
    }


    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var vm = StudioViewModel()

    // ── Room picker ────────────────────────────────────────
    // The inline two-axis rolodex (RoomRolodexView) is the room/zone selector;
    // it lives at the top of the Studio content and owns its own state.

    // ── Deck paging ───────────────────────────────────────
    @State private var currentDeck: Int = 0  // 0 = Effects, 1 = Live, 2 = Composer

    // ── Composer (Deck 3) ──────────────────────────────────
    @State private var composerCategory: PresetCategory = .all
    /// Collapsed section headers in the All view, persisted as CSV of
    /// PresetCategory raw values (AppStorage can't hold a Set directly).
    @AppStorage("composerCollapsedSections") private var collapsedComposerSectionsCSV = ""
    private var collapsedComposerSections: Set<String> {
        get { Set(collapsedComposerSectionsCSV.split(separator: ",").map(String.init)) }
        nonmutating set { collapsedComposerSectionsCSV = newValue.sorted().joined(separator: ",") }
    }
    @State private var renameCompositionTarget: CompositionPreset?
    @State private var renameCompositionText = ""
    // Round 3 (C): Perform surface. The VM is created ONCE at button tap —
    // building it inside the cover closure would recreate it on every
    // body re-evaluation while presented. Assigning it also *presents* the
    // cover (`item:`); dismissal nils it back out.
    @State private var performVM: PerformanceViewModel? = nil
    @State private var composerCreateBorderPhase: CGFloat = 0
    @State private var activeCompositionTab: CompositionLayerTab = .palette
    @State private var showCompositionSaveSheet = false
    @State private var compositionSaveName = ""
    @State private var compositionSaveIcon = "sparkles"
    @State private var compositionSaveAccent = "#FFB340"
    @State private var compositionSaveTransport: CompositionSaveTransportOption = .entertainmentArea
    @State private var compositionSaveCategory: PresetCategory = .myCreations
    @State private var isAIPromptExpanded = false
    @State private var aiPromptText = ""

    // ── Harmony Engine ────────────────────────────────────────
    @State private var activeHarmonyRule: HarmonyRule = .none
    @State private var editingSwatch: SwatchEditItem? = nil
    @State private var isMixerCollapsed = false
    @State private var isMixerExpanded = false
    @State private var showCompositionTransportPrompt = false
    @State private var pendingCompositionCard: StudioCard?
    @State private var pendingCompositionRoom: RoomDisplayItem?
    @State private var transportSwitchInFlightRoomIDs: Set<String> = []
    @State private var compositionDeleteTarget: CompositionPreset?
    @FocusState private var aiPromptFocused: Bool

    // ── Sharing (QR) ──────────────────────────────────────────
    // Studio owns the only CompositionStore, so a scene arriving from a share
    // link or a scanned QR is imported here — never in the deep-link handler,
    // which decodes but does not save.
    @State private var shareTarget: CompositionPreset?
    @State private var bridgeExportTarget: CompositionPreset?
    @State private var bridgeExportName = ""
    @State private var showSceneScanner = false
    @State private var importRequest: ImportRequest?
    @State private var importFailure: ImportFailure?

    /// `.sheet(item:)` needs identity; a SharedScene has none by design.
    private struct ImportRequest: Identifiable {
        let id = UUID()
        let scene: SharedScene
    }
    private struct ImportFailure: Identifiable {
        let id = UUID()
        let error: ScenePayloadError
    }


    // ── Performance ───────────────────────────────────────
    @State private var blurReady = false  // deferred to avoid first-frame GPU hitch

    var body: some View {
        GeometryReader { geo in
            let hasCurrentRoomEffect = vm.currentRoomEffect != nil
            let mixerVisible = hasCurrentRoomEffect && !isMixerCollapsed
            let mixerHeight: CGFloat = mixerVisible ? resolvedMixerHeight(proxy: geo) : 0
            let isEntertainmentRunning = vm.currentRoomEffect?.card.isEntertainmentScoped ?? false

            ZStack {
                ambientBackground

                if mixerVisible {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hideKeyboard()
                            collapseMixer()
                            HapticManager.shared.light()
                        }
                }

                VStack(spacing: 0) {
                    // ── Zone A: Inline two-axis room/zone rolodex ─
                    if !isEntertainmentRunning {
                        roomRolodex
                            .padding(.horizontal, HueSpacing.lg)
                            .padding(.vertical, HueSpacing.xs)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // ── Zone B: Living Card Grid ──────────────────
                    cardGrid
                        .frame(maxHeight: .infinity)
                        .onReceive(NotificationCenter.default.publisher(for: .compositionMicPermissionDenied)) { _ in
                            // Previously a dead wire: mic denial during a
                            // reactive composition failed silently.
                            vm.statusMessage = "⚠ Microphone unavailable — enable access in Settings"
                        }

                    // ── Deck page indicator ───────────────────────
                    deckDots
                        .padding(.bottom, HueSpacing.sm)

                    if hasCurrentRoomEffect && isMixerCollapsed {
                        Button {
                            expandMixer()
                            HapticManager.shared.selection()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(HuePalette.Noir.success)
                                    .frame(width: 6, height: 6)
                                Text("Live Controls")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(HuePalette.amber.opacity(0.9))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.10))
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 6)
                    }

                    // Tab bar clearance
                    Color.clear.frame(height: 80)
                }

                if mixerVisible {
                    VStack {
                        Spacer()
                    MixerTrayView(
                        vm: vm,
                        isMixerExpanded: $isMixerExpanded,
                        performVM: $performVM,
                        activeCompositionTab: $activeCompositionTab,
                        activeHarmonyRule: $activeHarmonyRule,
                        editingSwatch: $editingSwatch,
                        onCollapse: { collapseMixer() },
                        onSaveComposition: { card in
                            compositionSaveName = card.name == "New Composition" ? "" : card.name
                            compositionSaveIcon = card.icon
                            compositionSaveTransport = vm.compositionTransportPreference == .roomOnly ? .roomOnly : .entertainmentArea
                            showCompositionSaveSheet = true
                        },
                        onTransportSwitch: { effect, preferEntertainment in
                            switchRunningCompositionTransport(effect, preferEntertainment: preferEntertainment)
                        }
                    )
                    .frame(height: mixerHeight)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .padding(.bottom, studioTabBarClearance(bottomInset: geo.safeAreaInsets.bottom))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if vm.hasAnyRunningEffect {
                    Button {
                        Task { await vm.stopAll() }
                        HapticManager.shared.medium()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(HuePalette.Noir.destructive)
                    }
                    .accessibilityLabel("Stop all running effects")
                }
            }
            ToolbarItem(placement: .principal) {
                studioNavTitle
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.configure(orchestrator: orchestrator)
            // Defer blur to avoid ~2ms GPU hitch on first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.4)) { blurReady = true }
            }
        }
        .onChange(of: vm.selectedRoom?.id) { _, _ in
            isMixerCollapsed = false
            isMixerExpanded = false
        }
        // Coverage badges for Deck 0 — refires on room switch, auto-cancels
        // stale fetches on rapid rolodex scrubs (R4 Effects port).
        .task(id: vm.selectedRoom?.id) {
            await vm.refreshCoverage()
        }
        // Warms the entertainment-config cache so the transport menu can say
        // "no entertainment area" instead of hedging. One GET per bridge; the
        // orchestrator skips bridges it has already asked about.
        .task(id: vm.selectedRoom?.bridgeID) {
            await orchestrator.refreshEntertainmentConfigs(for: vm.selectedRoom)
        }
        .onChange(of: vm.runningCardID) { _, newValue in
            if newValue == nil {
                isMixerCollapsed = false
                isMixerExpanded = false
            }
        }
        .onChange(of: vm.restoredHarmonyRule) { _, rule in
            if let rule { activeHarmonyRule = rule }
        }
        .onChange(of: activeHarmonyRule) { _, newRule in
            guard let box = vm.activeCompositionBox else { return }
            if newRule == .none {
                box.palette.color3 = nil
                box.palette.color2 = CodableColor(x: 0.6400, y: 0.3300)
                box.palette.harmonyRule = nil
            } else {
                if box.palette.mode != .gradient { box.palette.mode = .gradient }
                box.palette.harmonyRule = newRule.rawValue
                applyHarmonyToComposition()
            }
            box.triggerRESTBurst()
        }
        .animation(HueAnimation.slow, value: vm.currentRoomEffect != nil)
        .animation(HueAnimation.card, value: vm.runningCardID)
        .alert("Save to Bridge", isPresented: Binding(
            get: { bridgeExportTarget != nil },
            set: { if !$0 { bridgeExportTarget = nil } }
        )) {
            TextField("Scene name", text: $bridgeExportName)
            Button("Cancel", role: .cancel) { bridgeExportTarget = nil }
            Button("Save") {
                guard let preset = bridgeExportTarget else { return }
                let name = bridgeExportName
                bridgeExportTarget = nil
                Task { await vm.exportPresetAsDynamicScene(preset, named: name) }
            }
        } message: {
            Text("The bridge cycles this palette on its own — no phone needed. It appears in your Scenes tab.")
        }
        .alert("Rename Composition", isPresented: Binding(
            get: { renameCompositionTarget != nil },
            set: { if !$0 { renameCompositionTarget = nil } }
        )) {
            TextField("Name", text: $renameCompositionText)
            Button("Cancel", role: .cancel) {
                renameCompositionTarget = nil
            }
            Button("Save") {
                if let preset = renameCompositionTarget {
                    vm.renameCompositionPreset(id: preset.id, to: renameCompositionText)
                }
                renameCompositionTarget = nil
            }
        } message: {
            Text("This name appears on the Composer deck.")
        }
        .fullScreenCover(item: $performVM) { performer in
            PerformanceView(viewModel: performer,
                            presets: vm.compositionStore.presets)
        }
        .sheet(isPresented: $showCompositionSaveSheet) {
            compositionSaveSheet
        }
        .sheet(item: $shareTarget) { preset in
            ShareSceneSheet(preset: preset)
        }
        // Drain on dismiss, not inside `onFound`: presenting the import sheet
        // while the scanner is still dismissing drops it on the floor.
        .sheet(isPresented: $showSceneScanner, onDismiss: consumePendingShare) {
            ScanSceneView { url in deepLink.acceptShareLink(url) }
        }
        .sheet(item: $importRequest) { request in
            ImportSceneSheet(scene: request.scene, store: vm.compositionStore) { preset in
                // Land on the deck that now holds it, filtered so it is visible.
                currentDeck = 2
                composerCategory = preset.category
            }
        }
        .sheet(item: $importFailure) { failure in
            ImportSceneFailureSheet(error: failure.error)
        }
        // A share link or a scanned QR decodes in DeepLinkCoordinator; Studio
        // owns the store, so the confirmation and the save happen here. One
        // modifier, not three — this body sits at the Swift type-checker's
        // ceiling (AGENTS.md), so wiring is extracted, never stacked.
        .modifier(StudioDrainWiring(
            openToken: deepLink.openToken,
            retryKey: siriDrainRetryKey,
            drainShare: consumePendingShare,
            drainStudioAction: consumePendingStudioAction
        ))
        .confirmationDialog(
            "Choose Composer Transport",
            isPresented: $showCompositionTransportPrompt,
            titleVisibility: .visible
        ) {
            // First choice is remembered (two-tap rule: this dialog should
            // only ever be answered once). The transport badge on the
            // running deck switches it live any time after.
            Button("Entertainment Area (Streaming)") {
                vm.compositionTransportPreference = .entertainmentArea
                vm.isCompositionTransportPromptEnabled = false
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: true) }
                clearPendingCompositionTransportPrompt()
            }
            Button("Room Only (REST)") {
                vm.compositionTransportPreference = .roomOnly
                vm.isCompositionTransportPromptEnabled = false
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: false) }
                clearPendingCompositionTransportPrompt()
            }
            Button("Cancel", role: .cancel) {
                clearPendingCompositionTransportPrompt()
            }
        } message: {
            Text("Entertainment is smoother but controls the whole entertainment area; Room Only keeps scope local with REST pacing. Your choice is remembered — switch anytime from the transport badge on the running deck.")
        }
        .confirmationDialog(
            "Delete composition?",
            isPresented: Binding(
                get: { compositionDeleteTarget != nil },
                set: { if !$0 { compositionDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let preset = compositionDeleteTarget {
                    Task { await vm.deleteCompositionPreset(preset) }
                }
                compositionDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                compositionDeleteTarget = nil
            }
        } message: {
            Text("Saved presets are removed from My Creations. Built-in presets reset to their defaults.")
        }
    }

    /// Floating tab bar + home indicator — keeps mixer aligned above the bar on all phones.
    private func studioTabBarClearance(bottomInset: CGFloat) -> CGFloat {
        max(72, 56 + bottomInset)
    }

    private var isCompactStudio: Bool {
        UIScreen.main.bounds.height <= 700 || dynamicTypeSize.isAccessibilitySize
    }

    /// Caps tray height to available tab content so the mixer can use most of the screen on SE while keeping the deck visible.
    /// When expanded (dragged up), grows to near-full-screen so the whole composition editor is visible.
    private func resolvedMixerHeight(proxy: GeometryProxy) -> CGFloat {
        let base = computeMixerHeight()
        let half = min(base, max(300, proxy.size.height * 0.88))
        guard isMixerExpanded else { return half }
        // Near-full-screen: leave a small top peek and clear the floating tab bar below.
        let expanded = proxy.size.height
            - proxy.safeAreaInsets.top
            - studioTabBarClearance(bottomInset: proxy.safeAreaInsets.bottom)
            - 24
        return max(half, min(expanded, proxy.size.height * 0.92))
    }

    private func computeMixerHeight() -> CGFloat {
        guard let effect = vm.currentRoomEffect else { return 0 }
        if case .composition = effect.card.strategy {
            return MixerTrayMetrics.compositionHeight(isCompact: isCompactStudio)
        }
        return MixerTrayMetrics.engineHeight(for: effect.card, isCompact: isCompactStudio)
    }

    private var allCards: [StudioCard] {
        vm.effectCards + vm.liveModeCards
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                HuePalette.Noir.background

                if blurReady {
                    Circle()
                        .fill(RadialGradient(
                            colors: [HuePalette.amber.opacity(0.20), .clear],
                            center: .center, startRadius: 0, endRadius: 180
                        ))
                        .frame(width: 360)
                        .position(x: geo.size.width * 0.85, y: 120)
                        .blur(radius: 30)

                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hex: "#8C59FF").opacity(0.18), .clear],
                            center: .center, startRadius: 0, endRadius: 150
                        ))
                        .frame(width: 300)
                        .position(x: geo.size.width * 0.15, y: geo.size.height * 0.65)
                        .blur(radius: 24)
                }
            }
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Nav title
    // Compact status label; the room/zone selector is the inline rolodex below.
    // ──────────────────────────────────────────────

    private var studioNavTitle: some View {
        let isEntRunning = vm.currentRoomEffect?.card.isEntertainmentScoped ?? false
        return Group {
            if isEntRunning {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Entertainment Area")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(vm.currentRoomEffect?.card.accentColor ?? .white)
            } else {
                Text("Studio")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone A: Inline Room Rolodex
    // Two-axis wheel: vertical = rooms, horizontal = zones. A search affordance
    // inside reveals RoomPickerSheetView as a large-library / a11y fallback.
    // ──────────────────────────────────────────────

    private var roomRolodex: some View {
        RoomRolodexView(
            rooms: orchestrator.allRooms,
            zones: orchestrator.allZones,
            selectedRoom: vm.selectedRoom,
            runningEffects: vm.runningEffects,
            onSelect: { room in
                withAnimation(HueAnimation.fast) {
                    vm.selectedRoom = room
                }
            }
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone B: Card Grid (paged)
    // ──────────────────────────────────────────────

    private var cardGrid: some View {
        TabView(selection: $currentDeck) {
            // Deck 0: Effects — built-ins, then Composer creations that move
            deckGrid(cards: vm.effectCards, deckIndex: 0,
                     composerPresets: vm.composerEffectPresets)
                .tag(0)

            // Deck 1: Live Modes — built-ins, then Composer creations that listen
            deckGrid(cards: vm.liveModeCards, deckIndex: 1,
                     composerPresets: vm.composerLivePresets)
                .tag(1)

            // Deck 2: Composer (presets + Create)
            composerGrid(deckIndex: 2)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Avoid animating the entire deck subtree — reduces hitch when paging to Composer.
    }

    private func deckGrid(cards: [StudioCard], deckIndex: Int,
                          composerPresets: [CompositionPreset] = []) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: HueSpacing.md),
            GridItem(.flexible(), spacing: HueSpacing.md)
        ]
        let visible = currentDeck == deckIndex

        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                ForEach(cards) { card in
                    StudioCardView(
                        card: card,
                        isRunning: vm.runningCardID == card.id,
                        roomSelected: vm.selectedRoom != nil,
                        isVisible: visible,
                        // Decorative signature for engine cards — they have no
                        // MotionConfig; bounce reads as generic activity.
                        patternSignature: .bounce,
                        coverageLabel: {
                            guard deckIndex == 0,
                                  case .bridgeNative = card.strategy,
                                  let cov = vm.effectCoverage[card.id],
                                  !cov.isFull else { return nil }
                            return cov.isEmpty
                                ? "NOT SUPPORTED"
                                : "\(cov.label.uppercased()) LIGHTS"
                        }()
                    ) {
                        if vm.runningCardID == card.id {
                            if isMixerCollapsed {
                                expandMixer()
                                HapticManager.shared.selection()
                            } else {
                                Task { await vm.explicitStop(card) }
                            }
                        } else {
                            isMixerCollapsed = false
                            applyCardWithTransportPrompt(card)
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, HueSpacing.sm)

            // ── From Composer ─────────────────────────────────
            // Creations that behave like this deck's built-ins, classified
            // from their own layers (PresetSurfaceClassifier). Full cards —
            // apply, tray, transport, overflow menu — not shortcuts.
            if !composerPresets.isEmpty {
                VStack(alignment: .leading, spacing: HueSpacing.md) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HuePalette.amber.opacity(0.8))
                        Text("FROM COMPOSER")
                            .font(HueFont.stageTag)
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.55))
                        Text("\(composerPresets.count)")
                            .font(HueFont.stageTag)
                            .foregroundStyle(.white.opacity(0.30))
                        Spacer()
                    }

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: HueSpacing.md),
                        GridItem(.flexible(), spacing: HueSpacing.md)
                    ], spacing: HueSpacing.md) {
                        ForEach(composerPresets) { preset in
                            composerPresetCell(preset: preset, visible: currentDeck == deckIndex)
                        }
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.bottom, HueSpacing.sm)
            }
        }
    }

    // ── Deck 3: Composer ─────────────────────────────────────

    private var composerCategoryChips: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PresetCategory.allCases) { category in
                        composerCategoryChip(category)
                    }
                }
                .padding(.vertical, 2)
            }

            // Receiving end of Share…: point the camera at someone else's QR.
            Button {
                showSceneScanner = true
                HapticManager.shared.light()
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HuePalette.amber)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(HuePalette.amber.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Scan a shared scene")
        }
    }

    private func composerCategoryChip(_ category: PresetCategory) -> some View {
        let selected = composerCategory == category
        let holidayHot = category == .holiday && vm.hasSeasonalCompositionPreset

        return Button {
            composerCategory = category
            HapticManager.shared.selection()
        } label: {
            Text(category.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? HuePalette.amber : .white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selected
                              ? HuePalette.amber.opacity(0.18)
                              : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            holidayHot ? HuePalette.amber.opacity(selected ? 0.55 : 0.42) : Color.white.opacity(selected ? 0.18 : 0.08),
                            lineWidth: holidayHot ? (selected ? 1.5 : 1.0) : 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func composerCreateHero(visible: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: HueRadius.xl)
                .fill(Color.white.opacity(0.06))

            RoundedRectangle(cornerRadius: HueRadius.xl)
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            HuePalette.amber,
                            Color(hex: "#8C59FF"),
                            HuePalette.amber.opacity(0.35),
                            HuePalette.amber
                        ],
                        center: .center,
                        angle: .degrees(composerCreateBorderPhase * 360)
                    ),
                    lineWidth: 2
                )

            Group {
                if isAIPromptExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(HuePalette.amber)
                            Text("Generate with AI")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            if vm.isGeneratingAIComposition {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(HuePalette.amber)
                            }
                        }

                        TextField("Describe the vibe (e.g. ocean calm with soft pulse)", text: $aiPromptText, axis: .vertical)
                            .focused($aiPromptFocused)
                            .lineLimit(1...2)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(vm.suggestedAIPrompts, id: \.self) { suggestion in
                                    Button {
                                        aiPromptText = suggestion
                                        triggerAIGeneration(with: suggestion)
                                        HapticManager.shared.selection()
                                    } label: {
                                        Text(suggestion)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule().fill(Color.white.opacity(0.08))
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(vm.isGeneratingAIComposition)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Cancel") {
                                isAIPromptExpanded = false
                                aiPromptText = ""
                                aiPromptFocused = false
                                vm.aiGenerationErrorMessage = nil
                                HapticManager.shared.light()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                            .buttonStyle(.plain)
                            .disabled(vm.isGeneratingAIComposition)

                            Spacer()

                            Button {
                                triggerAIGeneration(with: aiPromptText)
                            } label: {
                                Text(vm.isGeneratingAIComposition ? "Generating..." : "Generate")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.black.opacity(vm.isGeneratingAIComposition ? 0.5 : 0.9))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(HuePalette.amber.opacity(vm.isGeneratingAIComposition ? 0.45 : 0.95))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isGeneratingAIComposition || aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(HueSpacing.lg)
                } else {
                    HStack(spacing: HueSpacing.md) {
                        Button {
                            Task { await vm.applyStarterComposition() }
                            HapticManager.shared.medium()
                        } label: {
                            HStack(spacing: HueSpacing.md) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(HuePalette.amber)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("+ Create")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("Build your own effect")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.42))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(HueAnimation.fast) {
                                isAIPromptExpanded = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                aiPromptFocused = true
                            }
                            vm.aiGenerationErrorMessage = nil
                            HapticManager.shared.selection()
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(HuePalette.amber)
                                .padding(10)
                                .background(
                                    Circle().fill(HuePalette.amber.opacity(0.14))
                                )
                                .overlay(
                                    Circle().strokeBorder(HuePalette.amber.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Generate with AI")
                    }
                    .padding(HueSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: isAIPromptExpanded ? 146 : 76)
        .animation(HueAnimation.fast, value: isAIPromptExpanded)
        .opacity(visible ? 1 : 0.999)
        .onAppear {
            composerCreateBorderPhase = 0
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                composerCreateBorderPhase = 1
            }
        }
    }

    private func composerGrid(deckIndex: Int) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: HueSpacing.md),
            GridItem(.flexible(), spacing: HueSpacing.md)
        ]
        let visible = currentDeck == deckIndex
        let presets = vm.composerPresets(for: composerCategory)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: isCompactStudio ? HueSpacing.sm : HueSpacing.md) {
                composerCategoryChips

                if vm.hasSeasonalCompositionPreset {
                    HStack(spacing: 8) {
                        Text("Seasonal picks are live")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HuePalette.amber)
                        Spacer()
                        Text("Holiday")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HuePalette.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(HuePalette.amber.opacity(0.16))
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(HuePalette.amber.opacity(0.20), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                composerCreateHero(visible: visible)

                if let error = vm.aiGenerationErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HuePalette.Noir.destructive)
                        .padding(.horizontal, 4)
                }

                if presets.isEmpty {
                    Text("No presets in this category.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HueSpacing.lg)
                }

                if composerCategory == .all {
                    // 56 built-ins made one flat grid a wall. The All view
                    // groups by category — the user's own work first — behind
                    // collapsible headers whose state survives relaunch.
                    ForEach(vm.composerSections(), id: \.category) { section in
                        composerSectionHeader(category: section.category,
                                              count: section.presets.count)
                        if !collapsedComposerSections.contains(section.category.rawValue) {
                            LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                                ForEach(section.presets) { preset in
                                    composerPresetCell(preset: preset, visible: visible)
                                }
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                        ForEach(presets) { preset in
                            composerPresetCell(preset: preset, visible: visible)
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, isCompactStudio ? 6 : HueSpacing.sm)
        }
    }

    /// One preset card + its overflow menu — shared by the flat (filtered)
    /// grid and the sectioned All view.
    private func composerPresetCell(preset: CompositionPreset, visible: Bool) -> some View {
        let card = vm.studioCard(for: preset)
        return ZStack(alignment: .topTrailing) {
            StudioCardView(
                card: card,
                isRunning: vm.runningCardID == card.id,
                roomSelected: vm.selectedRoom != nil,
                isVisible: visible,
                patternSignature: preset.motion.pattern
            ) {
                if vm.runningCardID == card.id {
                    if isMixerCollapsed {
                        expandMixer()
                        HapticManager.shared.selection()
                    } else {
                        Task { await vm.explicitStop(card) }
                    }
                } else {
                    isMixerCollapsed = false
                    applyCardWithTransportPrompt(card)
                }
            }

            Menu {
                composerPresetOverflowActions(preset: preset, card: card)
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(8)
                    .background(Circle().fill(Color.black.opacity(0.38)))
            }
            .menuStyle(.button)
            .padding(6)
            .accessibilityLabel("Composition actions")
        }
        .contextMenu {
            composerPresetOverflowActions(preset: preset, card: card)
        }
    }

    private func composerSectionHeader(category: PresetCategory, count: Int) -> some View {
        let isCollapsed = collapsedComposerSections.contains(category.rawValue)
        return Button {
            withAnimation(HueAnimation.fast) {
                if isCollapsed {
                    collapsedComposerSections.remove(category.rawValue)
                } else {
                    collapsedComposerSections.insert(category.rawValue)
                }
            }
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 6) {
                Text(category.rawValue.uppercased())
                    .font(HueFont.stageTag)
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                Text("\(count)")
                    .font(HueFont.stageTag)
                    .foregroundStyle(.white.opacity(0.30))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.rawValue), \(count) presets, \(isCollapsed ? "collapsed" : "expanded")")
    }

    // ── Deck switcher ────────────────────────────────────────

    private static let deckNames = ["Effects", "Live", "Composer"]

    /// Named, tappable deck switcher — replaces the swipe-only page dots so
    /// reaching any deck is one tap with an explicit destination. Swiping
    /// the TabView still works.
    private var deckDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.deckNames.enumerated()), id: \.offset) { i, name in
                Button {
                    withAnimation(HueAnimation.fast) { currentDeck = i }
                    HapticManager.shared.selection()
                } label: {
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(currentDeck == i ? HuePalette.amber : .white.opacity(0.45))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(currentDeck == i ? HuePalette.amber.opacity(0.15) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(currentDeck == i ? .isSelected : [])
            }
        }
    }

    private func collapseMixer() {
        withAnimation(HueAnimation.fast) {
            isMixerCollapsed = true
            isMixerExpanded = false
        }
    }

    private func expandMixer() {
        withAnimation(HueAnimation.fast) {
            isMixerCollapsed = false
        }
    }

    private func triggerAIGeneration(with prompt: String) {
        let roomSnapshot = vm.selectedRoom
        Task {
            if let preset = await vm.generateCompositionFromPrompt(prompt) {
                await vm.apply(vm.studioCard(for: preset), roomOverride: roomSnapshot, preferEntertainmentOverride: nil)
                aiPromptText = ""
                isAIPromptExpanded = false
                aiPromptFocused = false
                HapticManager.shared.medium()
            } else {
                HapticManager.shared.light()
            }
        }
    }

    private func applyCardWithTransportPrompt(_ card: StudioCard) {
        let roomSnapshot = vm.selectedRoom
        guard case .composition = card.strategy else {
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
            return
        }
        if card.compositionTier == .bridgeOptimized || !vm.isCompositionTransportPromptEnabled {
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
            return
        }
        pendingCompositionCard = card
        pendingCompositionRoom = roomSnapshot
        showCompositionTransportPrompt = true
    }

    private func clearPendingCompositionTransportPrompt() {
        pendingCompositionCard = nil
        pendingCompositionRoom = nil
    }

    // ──────────────────────────────────────────────
    // MARK: - Shared scene import
    // ──────────────────────────────────────────────

    /// Drains whatever the deep-link handler decoded. Runs on `.task` too, so a
    /// cold launch from a share link — which lands before Studio is realized —
    /// still finds its scene waiting.
    private func consumePendingShare() {
        // Never present the import sheet while the scanner sheet is still up —
        // SwiftUI drops a second sheet on the floor and the scan is lost. The
        // scanner's own onDismiss re-drains, so deferring here loses nothing.
        guard !showSceneScanner else { return }
        if let scene = deepLink.pendingSharedScene {
            importRequest = ImportRequest(scene: scene)
            deepLink.clearShare()
        } else if let error = deepLink.pendingShareError {
            importFailure = ImportFailure(error: error)
            deepLink.clearShare()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Siri studio action
    // ──────────────────────────────────────────────

    /// The cold-launch dependencies a pending Siri action waits on: any
    /// change re-fires the drain task.
    private var siriDrainRetryKey: String {
        "\(vm.compositionStore.isLoaded)-\(orchestrator.allRooms.count)-\(orchestrator.allZones.count)"
    }

    /// Drains a Siri "start X in Y". Both cold-launch dependencies retry via
    /// onChange: presets (store loads off-main) and rooms (loadAll). A target
    /// that resolved for Siri but has since been deleted clears the action
    /// with an honest status instead of waiting forever.
    private func consumePendingStudioAction() {
        guard let action = deepLink.pendingStudioAction else { return }
        switch action {
        case .composition(let presetID, let groupID):
            guard vm.compositionStore.isLoaded else { return }   // retried on isLoaded
            guard let preset = vm.compositionStore.presets.first(where: { $0.id == presetID }) else {
                deepLink.pendingStudioAction = nil
                vm.statusMessage = "⚠ That Composer scene no longer exists"
                return
            }
            guard let room = resolveStudioActionGroup(groupID) else { return }
            deepLink.pendingStudioAction = nil
            let card = vm.studioCard(for: preset)
            Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: nil) }

        case .effect(let effectID, let groupID):
            guard let card = (vm.effectCards + vm.liveModeCards).first(where: { $0.id == effectID }) else {
                deepLink.pendingStudioAction = nil
                vm.statusMessage = "⚠ That effect no longer exists"
                return
            }
            guard let room = resolveStudioActionGroup(groupID) else { return }
            deepLink.pendingStudioAction = nil
            Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: nil) }
        }
    }

    /// nil while rooms are still loading (retried); nil-and-clear is handled
    /// by the caller only for entities that can't arrive later.
    private func resolveStudioActionGroup(_ id: String) -> RoomDisplayItem? {
        if let room = orchestrator.allRooms.first(where: { $0.id == id }) { return room }
        if let zone = orchestrator.allZones.first(where: { $0.id == id }) { return zone }
        // Groups are loaded but the id is gone — the room was deleted after
        // Siri resolved it. Give up rather than hold the action hostage.
        if !orchestrator.allRooms.isEmpty || !orchestrator.allZones.isEmpty {
            deepLink.pendingStudioAction = nil
            vm.statusMessage = "⚠ That room no longer exists"
        }
        return nil
    }

    private func switchRunningCompositionTransport(_ effect: RunningEffect, preferEntertainment: Bool) {
        guard case .composition = effect.card.strategy else { return }
        let roomID = effect.room.id
        if transportSwitchInFlightRoomIDs.contains(roomID) { return }
        if preferEntertainment == effect.isEntertainment {
            HapticManager.shared.selection()
            return
        }
        isMixerCollapsed = false
        transportSwitchInFlightRoomIDs.insert(roomID)
        Task {
            await vm.apply(
                effect.card,
                roomOverride: effect.room,
                preferEntertainmentOverride: preferEntertainment
            )
            transportSwitchInFlightRoomIDs.remove(roomID)
        }
        HapticManager.shared.light()
    }

    private enum CompositionQuickApply {
        case defaultStudioRules
        case streaming
        case roomREST
        case matchSavedPreset
    }

    /// Applies a composition card with an explicit transport choice (skips the transport confirmation sheet).
    private func applyCompositionQuick(_ card: StudioCard, mode: CompositionQuickApply) {
        let roomSnapshot = vm.selectedRoom
        guard case .composition = card.strategy else { return }
        switch mode {
        case .defaultStudioRules:
            applyCardWithTransportPrompt(card)
        case .streaming:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: true) }
        case .roomREST:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: false) }
        case .matchSavedPreset:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
        }
    }

    @ViewBuilder
    private func composerPresetOverflowActions(preset: CompositionPreset, card: StudioCard) -> some View {
        Button {
            applyCompositionQuick(card, mode: .defaultStudioRules)
            HapticManager.shared.light()
        } label: {
            Label("Apply to Current Room", systemImage: "play.fill")
        }

        // Menus build their content when opened, so the synchronous Keychain
        // read inside `entertainmentAvailability` costs nothing per frame.
        let availability = orchestrator.entertainmentAvailability(for: vm.selectedRoom)

        Menu {
            Button {
                applyCompositionQuick(card, mode: .streaming)
                HapticManager.shared.light()
            } label: {
                Label("Entertainment Area (Streaming)", systemImage: "bolt.fill")
            }
            .disabled(!availability.canStream)

            Button {
                applyCompositionQuick(card, mode: .roomREST)
                HapticManager.shared.light()
            } label: {
                Label("Room Only (REST)", systemImage: "iphone")
            }
            Button {
                applyCompositionQuick(card, mode: .matchSavedPreset)
                HapticManager.shared.light()
            } label: {
                Label("Match Saved Preset", systemImage: "bookmark.fill")
            }

            // Say why the option above is greyed out, rather than letting the
            // user tap it and watch the effect quietly demote to REST.
            if let reason = availability.reason {
                Section(reason) { EmptyView() }
            }
        } label: {
            Label("Apply with Transport…", systemImage: "arrow.triangle.branch")
        }

        Menu {
            ForEach(TransportPreference.allCases) { option in
                Button {
                    vm.setPreferredTransport(option.presetValue, for: preset)
                    HapticManager.shared.selection()
                } label: {
                    if preset.preferredTransport == option.presetValue {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
                .disabled(option == .entertainmentArea && !availability.canStream)
            }
        } label: {
            Label("Preferred Engine…", systemImage: "bolt.badge.automatic")
        }

        Menu {
            ForEach(PresetCategory.allCases.filter { $0 != .all }) { category in
                Button {
                    vm.setCategory(category, for: preset)
                    HapticManager.shared.selection()
                } label: {
                    if preset.category == category {
                        Label(category.rawValue, systemImage: "checkmark")
                    } else {
                        Text(category.rawValue)
                    }
                }
            }
        } label: {
            Label("Move to Category…", systemImage: "folder")
        }

        Divider()

        Button {
            renameCompositionText = preset.name
            renameCompositionTarget = preset
            HapticManager.shared.light()
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            vm.duplicateCompositionPreset(preset)
            HapticManager.shared.light()
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Button {
            shareTarget = preset
            HapticManager.shared.light()
        } label: {
            Label("Share…", systemImage: "qrcode")
        }

        // The third engine: uploaded once, then the bridge runs it alone.
        // Mic-reactive scenes are the one thing a bridge cannot do.
        if BridgeDynamicSceneExporter.ineligibilityReason(for: preset) == nil {
            Button {
                bridgeExportName = preset.name
                bridgeExportTarget = preset
                HapticManager.shared.light()
            } label: {
                Label("Save to Bridge…", systemImage: "externaldrive.badge.checkmark")
            }
        }

        Divider()

        Button(role: .destructive) {
            compositionDeleteTarget = preset
            HapticManager.shared.light()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Harmony Apply Helper
    // ──────────────────────────────────────────────

    private func applyHarmonyToComposition() {
        guard activeHarmonyRule != .none,
              let box = vm.activeCompositionBox else { return }
        let current = box.palette.color1
        let hsb = HueColorUtils.hsb(fromX: current.x, y: current.y, brightness: 100)
        let paletteColors = HarmonyEngine.palette(
            rule: activeHarmonyRule,
            rootHue: hsb.h,
            saturation: hsb.s,
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
        box.triggerRESTBurst()
    }

    private var compositionSaveSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("My Composition", text: $compositionSaveName)
                }
                Section("Icon") {
                    let icons = ["sparkles", "sun.max.fill", "moon.stars.fill", "waveform.path.ecg", "flame.fill", "bolt.fill", "music.note", "wand.and.stars"]
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(icons, id: \.self) { icon in
                            Button {
                                compositionSaveIcon = icon
                                HapticManager.shared.selection()
                            } label: {
                                Image(systemName: icon)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(icon == compositionSaveIcon ? HuePalette.amber.opacity(0.2) : Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Accent") {
                    // User saves were hardcoded #FFB340 while AI/starter cards
                    // got distinctive accents — let creations stand out too.
                    let accents = ["#FFB340", "#FF6B6B", "#BF5AF2", "#5E9EFF",
                                   "#30D158", "#40D9BF", "#FF9F0A", "#F2F0EA"]
                    HStack(spacing: 6) {
                        ForEach(accents, id: \.self) { hex in
                            let isSelected = hex == compositionSaveAccent
                            Button {
                                compositionSaveAccent = hex
                                HapticManager.shared.selection()
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 2 : 0))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Category") {
                    // Where the preset files on the Composer deck. Chips, not a
                    // wheel — eight options should be one glance.
                    let categories = PresetCategory.allCases.filter { $0 != .all }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories) { category in
                                let selected = category == compositionSaveCategory
                                Button {
                                    compositionSaveCategory = category
                                    HapticManager.shared.selection()
                                } label: {
                                    Text(category.rawValue)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(selected ? .black : .white.opacity(0.75))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(selected
                                                           ? HuePalette.amber
                                                           : Color.white.opacity(0.08))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("Transport") {
                    Picker("Target", selection: $compositionSaveTransport) {
                        ForEach(CompositionSaveTransportOption.allCases) { option in
                            Text(option.segmentTitle).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Streaming uses the entertainment area when available. REST stays on this room’s grouped light.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                hideKeyboard()
            }
            .navigationTitle("Save Composition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCompositionSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        _ = vm.saveActiveComposition(
                            name: compositionSaveName,
                            icon: compositionSaveIcon,
                            accentColorHex: compositionSaveAccent,
                            preferredTransport: compositionSaveTransport.presetValue,
                            category: compositionSaveCategory
                        )
                        showCompositionSaveSheet = false
                        HapticManager.shared.medium()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

// MARK: - StudioCardView (Living Cards)
//
// Performance: receives value types only. Never sees the ViewModel.
// The card IS the button — tap to apply/stop. No Apply/Stop sub-buttons.
// Canvas animation plays behind content — unique per card ID.

struct StudioCardView: View, Equatable {

    // nonisolated: compares only Sendable stored values (String/Bool/enum);
    // the onTap closure is deliberately excluded from equality.
    nonisolated static func == (lhs: StudioCardView, rhs: StudioCardView) -> Bool {
        lhs.card.id == rhs.card.id && lhs.isRunning == rhs.isRunning && lhs.roomSelected == rhs.roomSelected && lhs.isVisible == rhs.isVisible && lhs.patternSignature == rhs.patternSignature && lhs.coverageLabel == rhs.coverageLabel
    }

    let card: StudioCard
    let isRunning: Bool
    let roomSelected: Bool
    let isVisible: Bool
    var patternSignature: MotionConfig.Pattern? = nil
    /// "N OF M LIGHTS" / "NOT SUPPORTED" firmware-effect coverage (Deck 0).
    var coverageLabel: String? = nil
    let onTap: () -> Void

    private var accentColor: Color { card.accentColor }

    var body: some View {
        Button {
            onTap()
            HapticManager.shared.medium()
        } label: {
            ZStack(alignment: .bottomLeading) {
                // ── Card background ─────────────────────────────
                RoundedRectangle(cornerRadius: HueRadius.xl)
                    .fill(isRunning
                          ? accentColor.opacity(0.13)
                          : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: HueRadius.xl)
                            .strokeBorder(
                                isRunning ? accentColor.opacity(0.55) : Color.white.opacity(0.08),
                                lineWidth: isRunning ? 1.5 : 1
                            )
                    )

                // ── Living Canvas animation ─────────────────────
                StudioCardCanvas(
                    cardID: card.id,
                    accentColor: accentColor,
                    isRunning: isRunning,
                    isVisible: isVisible
                )
                .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
                .allowsHitTesting(false)

                // ── Content ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(isRunning ? 0.28 : 0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: card.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(accentColor)
                            .symbolEffect(.pulse.byLayer, isActive: isRunning)
                    }

                    Spacer(minLength: HueSpacing.sm)

                    // Name
                    HStack(spacing: 5) {
                        Text(card.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if isRunning {
                            Circle()
                                .fill(HuePalette.Noir.success)
                                .frame(width: 6, height: 6)
                        }
                    }

                    // Tagline
                    Text(card.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let coverageLabel {
                        StageBadge(text: coverageLabel, style: .muted)
                            .padding(.top, 4)
                    }

                    if let activity = card.compositionLayerActivity {
                        HStack(spacing: 4) {
                            if card.isAIGenerated {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(HuePalette.amber.opacity(0.95))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(HuePalette.amber.opacity(0.14))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(HuePalette.amber.opacity(0.30), lineWidth: 1)
                                    )
                            }
                            layerChip("🎨", isActive: activity.palette)
                            layerChip("🌊", isActive: activity.motion)
                            layerChip("📈", isActive: activity.envelope)
                            layerChip("🎤", isActive: activity.reaction)
                        }
                        .padding(.top, 5)
                    }

                    // Live pattern signature while the card runs.
                    if isRunning, let patternSignature {
                        PatternStripView(pattern: patternSignature, accent: accentColor)
                            .padding(.top, 6)
                    }

                    if let tier = card.compositionTier {
                        HStack(spacing: 4) {
                            compactTierBadge(tier)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 4)
                    }

                    // Entertainment Area badge
                    if card.isEntertainmentScoped {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                            Text("Entertainment Area")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(accentColor.opacity(0.7))
                        .padding(.top, 4)
                    }
                }
                .padding(HueSpacing.lg)
            }
            .aspectRatio(0.9, contentMode: .fit)
        }
        .buttonStyle(StudioCardButtonStyle())
        .animation(HueAnimation.normal, value: isRunning)
    }
}

private func layerChip(_ symbol: String, isActive: Bool) -> some View {
    Text(symbol)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .foregroundStyle(isActive ? HuePalette.amber : .white.opacity(0.45))
        .background(
            Capsule().fill(
                isActive ? HuePalette.amber.opacity(0.16) : Color.white.opacity(0.06)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isActive ? HuePalette.amber.opacity(0.35) : Color.white.opacity(0.10),
                lineWidth: 1
            )
        )
}

private func compactTierBadge(_ tier: CompositionTier) -> some View {
    let title: String
    let icon: String
    let tint: Color
    switch tier {
    case .bridgeOptimized:
        title = "Bridge"
        icon = "bolt.fill"
        tint = HuePalette.amber
    case .hybrid:
        title = "Hybrid"
        icon = "arrow.triangle.merge"
        tint = HuePalette.amber
    case .runtimeOnly:
        title = "App Driven"
        icon = "iphone"
        tint = Color.white.opacity(0.78)
    }

    return HStack(spacing: 3) {
        Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
    }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        )
}

// MARK: - StudioCardButtonStyle
// ButtonStyle cooperates with parent TabView(.page) gestures.
// DragGesture(minimumDistance: 0) was eating horizontal swipes.

struct StudioCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(HueAnimation.fast, value: configuration.isPressed)
    }
}

// MARK: - StudioDrainWiring
// Deep-link/Siri drain wiring, extracted off StudioView's body (which is at
// the Swift type-checker's ceiling — AGENTS.md). Reproduces the exact former
// modifiers, behavior-identical: onChange(openToken) fires both drains (a
// warm re-fire of a share or "start X in Y"); `.task` on mount drains any
// pending share; `.task(id: retryKey)` re-runs the Siri drain as each
// cold-launch dependency lands (presets load off-main, rooms via loadAll).

private struct StudioDrainWiring: ViewModifier {
    let openToken: Int
    let retryKey: String
    let drainShare: () -> Void
    let drainStudioAction: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: openToken) { _, _ in
                drainShare()
                drainStudioAction()
            }
            .task { drainShare() }
            .task(id: retryKey) { drainStudioAction() }
    }
}
