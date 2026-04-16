// DashboardView.swift
// HueHome Pro — Epic 2 / Story 2.1
//
// Full glassmorphism redesign of the Story 1.3 native list.
// Architecture: dark ambient background → ScrollView of RoomCards on GlassmorphicCard.
// Toggles remain the control surface; drag gestures land in Story 2.2.

import SwiftUI
import SwiftData

// MARK: - DashboardView

struct DashboardView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var vm = DashboardViewModel()     // kept for console log lines only
    @State private var showLog         = false
    @State private var showSettings    = false
    @Query private var localRooms: [HueLocalRoom]
    @Environment(\.modelContext) private var modelContext

    // Ambient background orb positions (stable, no GeometryReader jitter)
    private let orb1Offset = CGPoint(x: -80, y: -180)
    private let orb2Offset = CGPoint(x: 130, y: 80)

    var body: some View {
        ZStack {
            ambientBackground

            Group {
                if orchestrator.isLoading && orchestrator.allRooms.isEmpty {
                    // Show shimmer skeleton while waiting for first real data
                    shimmerView
                } else if let error = orchestrator.errorMessage, orchestrator.allRooms.isEmpty {
                    errorView(error)
                } else {
                    roomScrollView
                }
            }
        }
        .navigationTitle("My Lights")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog)      { logSheet }
        .sheet(isPresented: $showSettings) {
            // SettingsView needs its own NavigationStack when shown as sheet
            NavigationStack {
                SettingsView(onForget: {
                    NotificationCenter.default.post(name: .hueBridgeUnpaired, object: nil)
                })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSettings = false }
                            .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.2))
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .task {
            // 1. Instantly show cached data (synchronous — no flicker)
            orchestrator.preloadCached(from: localRooms)
            // 2. Fetch live data in background (won't show loading indicator if cache loaded)
            await orchestrator.loadAll(cacheContext: modelContext)
            // 3. Keep SSE alive for real-time updates
            orchestrator.startSSE()
        }
        .preferredColorScheme(.dark)
    }


    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08)
                .ignoresSafeArea()

            // Orb 1 — warm amber, top-left
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1, green: 0.75, blue: 0.2).opacity(0.22), .clear],
                        center: .center, startRadius: 0, endRadius: 200
                    )
                )
                .frame(width: 340, height: 340)
                .offset(x: orb1Offset.x, y: orb1Offset.y)
                .blur(radius: 20)

            // Orb 2 — cool blue-purple, lower-right
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.4, green: 0.3, blue: 1).opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 180
                    )
                )
                .frame(width: 280, height: 280)
                .offset(x: orb2Offset.x, y: orb2Offset.y)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Scroll
    // ──────────────────────────────────────────────

    private var roomScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                LazyVStack(spacing: 14) {
                    ForEach(orchestrator.allRooms.indices, id: \.self) { i in
                        let room = orchestrator.allRooms[i]
                        RoomCard(
                            room: Binding(
                                get: { orchestrator.allRooms[safe: i] ?? room },
                                set: { _ in }
                            ),
                            onToggle: {
                                HapticManager.shared.light()
                                orchestrator.toggleRoom(room)
                            },
                            onBrightness: { brightness in
                                orchestrator.setBrightness(brightness, for: room)
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


    // ── Summary Header ────────────────────────────

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                let onCount = orchestrator.allRooms.filter { $0.isOn }.count
                Text(onCount == 0
                     ? "All lights off"
                     : "\(onCount) room\(onCount == 1 ? "" : "s") on")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))

                Text("\(orchestrator.allRooms.count) room\(orchestrator.allRooms.count == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()

            let anyOn = orchestrator.allRooms.contains { $0.isOn }
            Circle()
                .fill(anyOn ? Color.yellow : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
                .shadow(color: anyOn ? .yellow.opacity(0.9) : .clear, radius: 8)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showLog.toggle() } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            // Only show refresh spinner if no cached data displayed yet
            if orchestrator.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.8)
            } else {
                Button {
                    Task { await orchestrator.loadAll(cacheContext: modelContext) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Shimmer Skeleton
    // ──────────────────────────────────────────────

    private var shimmerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Skeleton header
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerBar(width: 120, height: 14)
                        ShimmerBar(width: 80, height: 11)
                    }
                    Spacer()
                    ShimmerBar(width: 9, height: 9, cornerRadius: 5)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                LazyVStack(spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        ShimmerCard()
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.yellow)
                .scaleEffect(1.6)
            Text("Loading rooms…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await orchestrator.loadAll(cacheContext: modelContext) } }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Console Log Sheet
    // ──────────────────────────────────────────────

    private var logSheet: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Dashboard Console")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                }
            }
        }
    }
}

// MARK: - RoomCard

struct RoomCard: View {

    @Binding var room: RoomDisplayItem
    let onToggle:     () -> Void
    let onBrightness: (Double) -> Void

    private var glowColor: Color { Color(red: 1.0, green: 0.76, blue: 0.2) }

    var body: some View {
        // ── Full card = NavigationLink ────────────────────────────────────
        // Tap anywhere on the card body navigates to the room detail.
        // The power button overlay sits on top and intercepts taps in its area.
        NavigationLink(value: room) {
            GlassmorphicCard(isActive: room.isOn, glowColor: glowColor) {
                VStack(spacing: 0) {
                    headerContent
                    if room.isOn {
                        BrightnessRow(
                            brightness: $room.brightness,
                            glowColor: glowColor,
                            onCommit: { onBrightness(room.brightness) }
                        )
                        .padding(.top, 6)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // ── Power button overlay ──────────────────────────────────────────
        // An overlay view is rendered above the NavigationLink label and
        // handles its own hit testing first — guaranteed to intercept taps.
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

    // ──────────────────────────────────────────────
    // MARK: - Header (inside NavigationLink label)
    // ──────────────────────────────────────────────

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 14) {
            // Archetype icon
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
            // Name + light count
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
            // Reserve space for power button overlay (prevents text overflow under it)
            Spacer().frame(width: 48)
        }
    }
}


// MARK: - BrightnessRow
//
// Self-contained scrubber. Only this view has a DragGesture,
// so the ScrollView above it retains full vertical scroll priority.

struct BrightnessRow: View {

    @Binding var brightness: Double
    let glowColor: Color
    let onCommit: () -> Void

    @State private var isDragging         = false
    @State private var dragStart: Double  = 0
    @State private var lastNotch: Int     = 0
    private let sensitivity: CGFloat      = 2.0

    var body: some View {
        HStack(spacing: 8) {
            // Dim icon
            Image(systemName: "sun.min.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))

            // Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 4)

                    // Fill
                    Capsule()
                        .fill(LinearGradient(
                            colors: [glowColor.opacity(0.6), glowColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(6, geo.size.width * CGFloat(brightness / 100)), height: 4)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                        .shadow(color: glowColor.opacity(0.6), radius: isDragging ? 6 : 3)
                        .offset(x: max(0, geo.size.width * CGFloat(brightness / 100) - (isDragging ? 8 : 6)))
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDragging)
                }
                .frame(height: 16)
                .contentShape(Rectangle().inset(by: -8))  // larger hit target
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStart  = brightness
                                lastNotch  = Int(brightness / 10)
                                HapticManager.shared.medium()
                            }
                            let delta  = Double(value.translation.width / sensitivity)
                            let newVal = min(100, max(1, dragStart + delta))
                            brightness = newVal

                            let notch = Int(newVal / 10)
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            HapticManager.shared.heavy()
                            onCommit()
                        }
                )
            }
            .frame(height: 16)

            // Bright icon + percentage
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(Int(brightness))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(.none, value: brightness)
            }
        }
        .padding(.top, 4)
    }
}

