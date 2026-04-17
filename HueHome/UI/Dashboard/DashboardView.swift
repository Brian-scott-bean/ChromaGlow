// DashboardView.swift
// HueHome Pro — Epic 2 / Story 2.1
//
// Performance re-pass (v0.3.3):
// ─────────────────────────────
// The previous @Bindable + $orch.allRooms[i] pattern wrote to @Observable
// on every drag tick (60 fps) → full view-tree re-render on each frame.
//
// Fix: RoomCard accepts a VALUE TYPE room, not a @Binding. BrightnessRow
// keeps its own @State var localBrightness and only calls onCommit() on
// drag END. Zero @Observable mutations during a drag. Result: silky 60 fps.

import SwiftUI
import SwiftData

// MARK: - DashboardView

struct DashboardView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showLog         = false
    @State private var showSettings    = false
    @Environment(\.modelContext)         private var modelContext
    @Environment(\.scenePhase)           private var scenePhase
    @Environment(\.horizontalSizeClass)  private var sizeClass



    /// Minimum seconds between auto-refreshes triggered by navigation or foregrounding.
    /// SSE handles real-time updates; this is a staleness fallback only.
    /// Pull-to-refresh always fires immediately regardless.
    private let refreshDebounceInterval: TimeInterval = 120

    var body: some View {
        ZStack {
            DashboardAmbientBackground()

            Group {
                if orchestrator.allRooms.isEmpty {
                    if orchestrator.isLoading {
                        shimmerView
                    } else {
                        emptyState
                    }
                } else {
                    roomScrollView
                }
            }
        }
        .navigationTitle(orchestrator.isDemoMode ? "My Lights  ✦ Demo" : "My Lights")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(onForget: { showSettings = false })
            }
        }
        .task {
            // Stale-while-revalidate: trigger a background loadAll() on every
            // dashboard appearance (startup, navigation-back from a room) if
            // data is older than refreshDebounceInterval seconds.
            // AppRootView already fires loadAll() at startup — the isLoading
            // guard inside loadAll() will suppress that concurrent initial call.
            let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
            guard staleness >= refreshDebounceInterval else { return }
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When app returns to foreground, refresh if data is stale.
            if newPhase == .active {
                let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
                if staleness >= refreshDebounceInterval {
                    Task { await orchestrator.loadAll(cacheContext: modelContext) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Scroll
    // ──────────────────────────────────────────────

    // NOTE: No @Bindable here. RoomCard takes a plain value-type RoomDisplayItem,
    // so ForEach never needs a Binding. This is intentional — see file header.
    private var roomScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                // Adaptive layout: 1-column on iPhone, 2-column grid on iPad.
                // LazyVGrid with a single flexible column is functionally identical to
                // LazyVStack but lets us switch columns without restructuring the ForEach.
                let columns: [GridItem] = sizeClass == .regular
                    ? [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
                    : [GridItem(.flexible())]

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        RoomCard(
                            room: room,
                            onToggle: { desiredOn in
                                // desiredOn is passed from RoomCard's localIsOn (post-flip),
                                // avoiding stale room.isOn captured from ForEach closure.
                                orchestrator.setRoom(room, isOn: desiredOn)
                            },
                            onBrightness: { newBrightness in
                                // Fires once at drag END — not during drag.
                                orchestrator.setBrightness(newBrightness, for: room)
                            }
                        )
                        .padding(.horizontal, sizeClass == .regular ? 0 : 20)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal:   .opacity
                        ))
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 20 : 0)
                .padding(.bottom, 100)   // clear custom tab bar
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allRooms.count)
            }
        }
        .overlay(alignment: .top) {
            if let msg = orchestrator.toastMessage {
                HueToastView(message: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: orchestrator.toastMessage)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: orchestrator.toastMessage)
        .navigationDestination(for: RoomDisplayItem.self) { room in
            RoomDetailView(room: room)
        }
        .refreshable {
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .scrollIndicators(.hidden)
    }


    // ──────────────────────────────────────────────
    // MARK: - Summary Header
    // ──────────────────────────────────────────────

    private var summaryHeader: some View {
        let onCount = orchestrator.allRooms.filter { $0.isOn }.count
        let total   = orchestrator.allRooms.count

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(onCount == 0
                     ? "All lights off"
                     : "\(onCount) of \(total) on")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(total) room\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Circle()
                .fill(onCount > 0 ? Color.yellow : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
                .shadow(color: onCount > 0 ? .yellow.opacity(0.9) : .clear, radius: 8)
        }
    }

    // ── ambientBackground moved to DashboardAmbientBackground struct (see below) ─
    // Extracting to a dedicated View struct ensures SwiftUI never re-renders the
    // blur-heavy orbs when orchestrator.allRooms changes due to SSE events.

    // ──────────────────────────────────────────────
    // MARK: - Empty / Loading / Shimmer
    // ──────────────────────────────────────────────

    private var shimmerView: some View {
        LazyVStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                ShimmerCard()
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lightbulb.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
            Text("No rooms found")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.55))
            Text("Pull to refresh or pair a bridge\nin Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if orchestrator.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.85)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - RoomCard
//
// Accepts a VALUE TYPE RoomDisplayItem — no @Binding.
// BrightnessRow inside has its own local @State so drags
// never touch the orchestrator's @Observable allRooms array.
// Full card = NavigationLink to detail.
// Power button = overlay, guaranteed to intercept first.
// ══════════════════════════════════════════════════════════

struct RoomCard: View {

    let room: RoomDisplayItem
    let onToggle:     (Bool) -> Void   // Bool = desired new on-state
    let onBrightness: (Double) -> Void   // called ONCE on drag end with final value

    // ── Local optimistic state ────────────────────────────────────────────────
    // localIsOn flips INSTANTLY on tap — no dependency on the @Observable chain.
    // Seeds from room.isOn on first appear; .onChange keeps it in sync when the
    // orchestrator confirms state (SSE, loadAll, API rollback).
    @State private var localIsOn: Bool

    init(room: RoomDisplayItem,
         onToggle: @escaping (Bool) -> Void,
         onBrightness: @escaping (Double) -> Void) {
        self.room         = room
        self.onToggle     = onToggle
        self.onBrightness = onBrightness
        // @State is seeded ONCE per view identity — SwiftUI preserves it across rerenders.
        _localIsOn = State(initialValue: room.isOn)
    }

    private var glowColor: Color { Color(red: 1.0, green: 0.76, blue: 0.2) }

    var body: some View {
        NavigationLink(value: room) {
            GlassmorphicCard(isActive: localIsOn, glowColor: glowColor) {
                VStack(spacing: 0) {
                    headerContent
                    if localIsOn {
                        BrightnessRow(
                            brightness: room.brightness,   // read-only snapshot
                            glowColor: glowColor,
                            onCommit: { onBrightness($0) } // $0 = final value on release
                        )
                        .padding(.top, 6)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // ── Power button overlay ──────────────────────────────────────────────
        .overlay(alignment: .topTrailing) {
            Button {
                HapticManager.shared.light()
                localIsOn.toggle()   // instant — never waits for @Observable
                onToggle(localIsOn)   // pass the NEW state — avoids stale room.isOn capture
            } label: {
                Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.35))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: localIsOn)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 14)
            .accessibilityLabel(Text("Turn \(room.name) \(localIsOn ? "off" : "on")"))
            .accessibilityHint(Text(localIsOn ? "Tap to turn off" : "Tap to turn on"))
        }
        .frame(minHeight: 88)
        .opacity(localIsOn ? 1.0 : 0.72)
        .scaleEffect(localIsOn ? 1.0 : 0.982)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: localIsOn)
        // ── Bridge-truth sync ─────────────────────────────────────────────────
        // Fires when room.isOn changes (SSE, loadAll, pull-to-refresh, API rollback).
        .onChange(of: room.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    localIsOn = confirmed
                }
            }
        }
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(localIsOn
                          ? glowColor.opacity(0.22)
                          : Color.white.opacity(0.07))
                    .frame(width: 48, height: 48)
                Image(systemName: archetypeIcon(for: room.archetype))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            Spacer().frame(width: 48)   // reserve space for power overlay
        }
    }
}


// ══════════════════════════════════════════════════════════
// MARK: - BrightnessRow
//
// Performance contract:
//   • brightness (Double)    — read-only value from parent
//   • onCommit((Double)->())  — called ONCE when drag ends
//
// During drag: only @State vars change → zero @Observable writes
//              → zero parent re-renders → 60 fps smooth.
// After drag:  onCommit fires which updates orchestrator/VM (one write).
// External sync: .onChange(of: brightness) updates localBrightness when
//              SSE pushes a new value from the bridge (not during drag).
// ══════════════════════════════════════════════════════════

struct BrightnessRow: View {

    // ── Inputs ──────────────────────────────────────────
    let brightness: Double   // current "truth" value from parent (read-only)
    let glowColor:  Color
    let onCommit:   (Double) -> Void   // fires once at gesture end

    // ── Local drag state — NEVER propagated to parent during drag ─────
    @State private var localBrightness: Double
    @State private var isDragging:  Bool   = false
    @State private var dragStart:   Double = 0
    @State private var lastNotch:   Int    = 0
    private let sensitivity: CGFloat = 2.0

    init(brightness: Double, glowColor: Color, onCommit: @escaping (Double) -> Void) {
        self.brightness = brightness
        self.glowColor  = glowColor
        self.onCommit   = onCommit
        // Seed local state — only used while dragging; see displayValue below.
        _localBrightness = State(initialValue: brightness)
    }

    // Always display localBrightness — never conditionally switch back to the parent
    // value mid-gesture. The snap-back bug was caused by setting isDragging=false
    // in onEnded (switching display to parent's stale value) before the parent
    // re-rendered with the committed value. onChange(of: brightness) syncs
    // localBrightness from SSE/parent updates when finger is off the slider.
    private var displayValue: Double { localBrightness }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 4)

                    // Filled portion
                    Capsule()
                        .fill(LinearGradient(
                            colors: [glowColor.opacity(0.6), glowColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(6, geo.size.width * CGFloat(displayValue / 100)), height: 4)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                        .shadow(color: glowColor.opacity(0.6), radius: isDragging ? 6 : 3)
                        .offset(x: max(0, geo.size.width * CGFloat(displayValue / 100) - (isDragging ? 8 : 6)))
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDragging)
                }
                .frame(height: 16)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging  = true
                                dragStart   = localBrightness  // use live local value, not stale parent prop
                                lastNotch   = Int(localBrightness / 10)
                                HapticManager.shared.medium()
                            }
                            let delta  = Double(value.translation.width / sensitivity)
                            let newVal = min(100, max(1, dragStart + delta))
                            localBrightness = newVal   // ← pure @State, no Observable cascade

                            let notch = Int(newVal / 10)
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            HapticManager.shared.heavy()
                            onCommit(localBrightness)   // ← ONE write to orchestrator after release
                        }
                )
            }
            .frame(height: 16)

            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(Int(displayValue))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
                    // numericText transition only runs when NOT dragging (too expensive at 60fps)
                    .contentTransition(isDragging ? .identity : .numericText())
                    .animation(isDragging ? .none : .default, value: displayValue)
            }
        }
        .padding(.top, 4)
        // Sync external value back (SSE update, toggle) only when finger is off slider
        .onChange(of: brightness) { _, new in
            if !isDragging { localBrightness = new }
        }
        // VoiceOver: treat the whole row as an adjustable element.
        // Users can swipe up/down to nudge brightness by 10% steps.
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int(displayValue)) percent")
        .accessibilityAdjustableAction { direction in
            let step: Double = 10
            let newVal: Double
            switch direction {
            case .increment: newVal = min(100, localBrightness + step)
            case .decrement: newVal = max(1,   localBrightness - step)
            @unknown default: return
            }
            localBrightness = newVal
            onCommit(newVal)
        }
    }
}


// MARK: - Ambient Background (isolated View — zero @Observable dependencies)

/// Renders the two blur-orb background gradient circles.
///
/// Isolated as its own View struct so SwiftUI's view-identity system treats it
/// as an OPAQUE, STABLE component. It has no @Environment(orchestrator) reads,
/// so SSE events that update allRooms do NOT cause this view to re-evaluate —
/// avoiding repeated off-screen CoreImage/blur render passes on every event.
///
/// Rule of thumb: anything with .blur() or complex gradients should live in its
/// own View with zero observed dependencies.
private struct DashboardAmbientBackground: View {
    private let orb1Offset = CGPoint(x: -80, y: -180)
    private let orb2Offset = CGPoint(x: 130, y: 80)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.75, blue: 0.2).opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 360)
                .offset(x: orb1Offset.x, y: orb1Offset.y)
                .blur(radius: 24)
                .allowsHitTesting(false)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 1).opacity(0.16), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 280)
                .offset(x: orb2Offset.x, y: orb2Offset.y)
                .blur(radius: 20)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        // drawingGroup() flattens the two blurred circles into a single Metal-composited
        // texture after first render. Subsequent passes re-use the cached texture instead
        // of re-running the CIGaussianBlur filter chain each time.
        .drawingGroup()
    }
}
