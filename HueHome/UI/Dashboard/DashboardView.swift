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
    @Environment(\.modelContext) private var modelContext

    // Ambient background orb positions (stable, no GeometryReader jitter)
    private let orb1Offset = CGPoint(x: -80, y: -180)
    private let orb2Offset = CGPoint(x: 130, y: 80)

    var body: some View {
        ZStack {
            ambientBackground

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
            await orchestrator.loadAll(cacheContext: modelContext)
            orchestrator.startSSE()
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

                LazyVStack(spacing: 14) {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        RoomCard(
                            room: room,
                            onToggle: {
                                HapticManager.shared.light()
                                orchestrator.toggleRoom(room)
                            },
                            onBrightness: { newBrightness in
                                // Fires once at drag END — not during drag.
                                orchestrator.setBrightness(newBrightness, for: room)
                            }
                        )
                        .padding(.horizontal, 20)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal:   .opacity
                        ))
                    }
                }
                .padding(.bottom, 100)   // clear custom tab bar
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allRooms.count)
            }
        }
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

    // ──────────────────────────────────────────────
    // MARK: - Ambient Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
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
    }

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
    let onToggle:     () -> Void
    let onBrightness: (Double) -> Void   // called ONCE on drag end with final value

    private var glowColor: Color { Color(red: 1.0, green: 0.76, blue: 0.2) }

    var body: some View {
        NavigationLink(value: room) {
            GlassmorphicCard(isActive: room.isOn, glowColor: glowColor) {
                VStack(spacing: 0) {
                    headerContent
                    if room.isOn {
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
        // ── Power button overlay ──────────────────────────────────────────
        .overlay(alignment: .topTrailing) {
            Button {
                HapticManager.shared.light()
                onToggle()
            } label: {
                Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(room.isOn ? glowColor : .white.opacity(0.35))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 14)
        }
        .frame(minHeight: 88)
        .opacity(room.isOn ? 1.0 : 0.72)
        .scaleEffect(room.isOn ? 1.0 : 0.982)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: room.isOn)
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(room.isOn
                          ? glowColor.opacity(0.22)
                          : Color.white.opacity(0.07))
                    .frame(width: 48, height: 48)
                Image(systemName: archetypeIcon(for: room.archetype))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(room.isOn ? glowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: room.isOn)
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

    // During drag use localBrightness (pure @State, no cascades).
    // At rest use the parent's brightness (reflects SSE/SSE updates instantly).
    private var displayValue: Double { isDragging ? localBrightness : brightness }

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
                                dragStart   = brightness   // snapshot at drag start
                                lastNotch   = Int(brightness / 10)
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
    }
}
