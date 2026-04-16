// RoomDetailView.swift
// HueHome Pro — Epic 3 / Story 3.1
//
// Individual light control drill-down.
// Reuses GlassmorphicCard, BrightnessRow, and archetypeIcon() from the dashboard layer.
// Each bulb card: tap = toggle, brightness scrubber = dimming.

import SwiftUI

// MARK: - RoomDetailView

struct RoomDetailView: View {

    let room: RoomDisplayItem
    @StateObject private var vm: RoomDetailViewModel
    @State private var showLog         = false
    @State private var showCreateScene = false

    init(room: RoomDisplayItem) {
        self.room = room
        _vm = StateObject(wrappedValue: RoomDetailViewModel(room: room))
    }

    var body: some View {
        ZStack {
            ambientBackground

            Group {
                if vm.isLoading && vm.lights.isEmpty {
                    loadingView
                } else if let error = vm.errorMessage, vm.lights.isEmpty {
                    errorView(error)
                } else {
                    lightScrollView
                }
            }
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showCreateScene) {
            CreateSceneView(lights: vm.lights) { name in
                await vm.createScene(name: name)
            }
        }
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await vm.loadLights() }
                group.addTask { await vm.loadScenes() }
                group.addTask { await vm.runSSE() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.75, blue: 0.2).opacity(0.18), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 340)
                .offset(x: 80, y: -160)
                .blur(radius: 20)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 1).opacity(0.14), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 260)
                .offset(x: -100, y: 120)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Light Scroll
    // ──────────────────────────────────────────────

    private var lightScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                // ── Scene strip (always shown when lights are loaded) ──
                if !vm.scenes.isEmpty || !vm.lights.isEmpty {
                    scenesStrip
                        .padding(.bottom, 20)
                }

                LazyVStack(spacing: 14) {
                    ForEach($vm.lights) { $light in
                        LightCard(light: $light, onToggle: {
                            HapticManager.shared.light()
                            vm.toggleLight(light)
                        }, onBrightness: { brightness in
                            vm.setBrightness(brightness, for: light)
                        })
                        .padding(.horizontal, 20)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.bottom, 32)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: vm.lights.count)
            }
        }
        .navigationDestination(for: LightDisplayItem.self) { light in
            if let binding = vm.lightBinding(for: light) {
                LightControlView(
                    light: binding,
                    // Read binding.wrappedValue at call time — never a stale snapshot.
                    onToggle:     { vm.toggleLight(binding.wrappedValue) },
                    onBrightness: { vm.setBrightness($0, for: binding.wrappedValue) },
                    onColor:      { x, y in vm.setColor(x: x, y: y, for: binding.wrappedValue) },
                    onColorTemp:  { vm.setColorTemp(mirek: $0, for: binding.wrappedValue) }
                )
            }
        }
        .refreshable { await vm.loadLights() }
        .scrollIndicators(.hidden)
    }

    // ── Scene Strip ───────────────────────────────

    private var scenesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: label + "＋" button
            HStack {
                Text("SCENES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    HapticManager.shared.light()
                    showCreateScene = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20).opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.scenes) { scene in
                        SceneChip(scene: scene) {
                            vm.activateScene(scene)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.deleteScene(scene)
                            } label: {
                                Label("Delete Scene", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }

    // ── Summary Header ────────────────────────────

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                let onCount = vm.lights.filter { $0.isOn }.count
                Text(onCount == 0
                     ? "All lights off"
                     : "\(onCount) of \(vm.lights.count) on")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(vm.lights.count) bulb\(vm.lights.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            let anyOn = vm.lights.contains { $0.isOn }
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
            if vm.isLoading {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(0.8)
            } else {
                Button { Task { await vm.loadLights() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Loading / Error
    // ──────────────────────────────────────────────

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().progressViewStyle(.circular).tint(.yellow).scaleEffect(1.6)
            Text("Loading lights…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadLights() } }
                .buttonStyle(.borderedProminent).tint(.orange)
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
            .navigationTitle("Light Console")
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

// MARK: - LightCard
//
// Individual bulb card.
// Full card = NavigationLink to LightControlView.
// Power button = overlay, guaranteed to intercept taps before the NavigationLink label.

struct LightCard: View {

    @Binding var light: LightDisplayItem
    let onToggle:     () -> Void
    let onBrightness: (Double) -> Void

    private var glowColor: Color { Color(red: 1.0, green: 0.76, blue: 0.2) }

    var body: some View {
        NavigationLink(value: light) {
            GlassmorphicCard(isActive: light.isOn, glowColor: glowColor) {
                VStack(spacing: 0) {
                    lightHeaderContent
                    if light.isOn {
                        BrightnessRow(
                            brightness: $light.brightness,
                            glowColor: glowColor,
                            onCommit: { onBrightness(light.brightness) }
                        )
                        .padding(.top, 6)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                HapticManager.shared.light()
                onToggle()
            } label: {
                Image(systemName: light.isOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.35))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 14)
        }
        .frame(minHeight: 80)
        .opacity(light.isOn ? 1.0 : 0.72)
        .scaleEffect(light.isOn ? 1.0 : 0.982)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: light.isOn)
    }

    private var lightHeaderContent: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(light.isOn ? glowColor.opacity(0.22) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: archetypeIcon(for: light.archetype))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(light.isOn ? glowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: light.isOn)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(light.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(light.isOn ? "\(Int(light.brightness))%" : "Off")
                    .font(.caption)
                    .foregroundStyle(light.isOn ? glowColor.opacity(0.8) : .white.opacity(0.40))
            }
            Spacer()
            // Capability badge (visual only)
            if light.supportsColor {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            } else if light.supportsColorTemp {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            // Reserve space for power overlay
            Spacer().frame(width: 44)
        }
    }
}
