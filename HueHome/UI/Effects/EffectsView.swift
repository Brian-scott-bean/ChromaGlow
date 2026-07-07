// EffectsView.swift
// CastChroma — Effects Tab
//
// Main Effects tab: room selector, category filter, 2-column effect grid,
// expandable controls panel, and Activate button.

import SwiftUI

// MARK: - EffectsView

struct EffectsView: View {

    @StateObject private var vm = EffectsViewModel()
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    // Accent colours
    private let amber  = Color(red: 1.0,  green: 0.76, blue: 0.20)
    private let purple = Color(red: 0.55, green: 0.35, blue: 1.00)
    private let teal   = Color(red: 0.25, green: 0.85, blue: 0.75)
    private let pink   = Color(red: 1.0,  green: 0.30, blue: 0.55)

    @State private var showEffectsMenu  = false   // confirmationDialog for multi-effect stop
    @AppStorage("castchroma.useWideCards") private var useWideCards = false

    // Saved presets CRUD
    @ObservedObject private var presetsStore  = EffectPresetsStore.shared
    @State private var showSaveAlert          = false
    @State private var presetInputName        = ""
    @State private var presetToDelete: SavedEffectPreset? = nil
    @State private var showDeletePresetAlert  = false
    @State private var presetToRename: SavedEffectPreset? = nil
    @State private var showRenamePresetAlert  = false

    private var gridColumns: [GridItem] {
        useWideCards
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    // Room list from orchestrator for the top selector
    private var rooms: [RoomDisplayItem] { orchestrator.allRooms }

    var body: some View {
        // Split into mainContent + alerts to stay within Swift's type-checker budget.
        // (14 chained modifiers on a complex ZStack causes a timeout without this split.)
        mainContent
            // Save-as-preset alert
            .alert("Save as Preset", isPresented: $showSaveAlert) {
                TextField("Preset name", text: $presetInputName)
                Button("Save") {
                    let name = presetInputName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let data = vm.buildPresetData(name: name) {
                        presetsStore.save(data)
                    }
                    presetInputName = ""
                }
                Button("Cancel", role: .cancel) { presetInputName = "" }
            } message: {
                Text("Save your current \"\(vm.selectedEffect?.name ?? "")\" settings as a reusable preset.")
            }
            // Rename preset alert
            .alert("Rename Preset", isPresented: $showRenamePresetAlert, presenting: presetToRename) { preset in
                TextField("Name", text: $presetInputName)
                Button("Rename") {
                    let name = presetInputName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { presetsStore.rename(preset, to: name) }
                    presetToRename = nil; presetInputName = ""; showRenamePresetAlert = false
                }
                Button("Cancel", role: .cancel) {
                    presetToRename = nil; presetInputName = ""; showRenamePresetAlert = false
                }
            }
            // Delete preset alert
            .alert("Delete Preset", isPresented: $showDeletePresetAlert, presenting: presetToDelete) { preset in
                Button("Delete \"\(preset.name)\"", role: .destructive) {
                    presetsStore.delete(preset)
                    presetToDelete = nil; showDeletePresetAlert = false
                }
                Button("Cancel", role: .cancel) { presetToDelete = nil; showDeletePresetAlert = false }
            } message: { preset in
                Text("\"\(preset.name)\" will be removed from your saved presets.")
            }
    }

    // MARK: - Main Content (navigation + toolbar + animations — without alerts)

    private var mainContent: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Running banner ──────────────────────────
                    if vm.isRunning, let name = vm.runningEffectName {
                        runningBanner(name: name)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    // ── Room selector ───────────────────────────
                    roomSelector
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    // ── My Presets ──────────────────────────────
                    if !presetsStore.presets.isEmpty {
                        myPresetsRow
                            .padding(.top, 4)
                            .padding(.bottom, 4)
                    }

                    // ── Category filter ─────────────────────────
                    categoryFilter
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    // ── Effect grid ─────────────────────────────
                    effectGrid
                        .padding(.horizontal, 20)

                    // ── Controls panel ──────────────────────────
                    if let effect = vm.selectedEffect {
                        EffectControlsView(effect: effect, vm: vm)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Bottom pad for tab bar
                    Color.clear.frame(height: 120)
                }
            }

            // ── Floating pill for app-driven effects ──────────────
            if let effect = vm.selectedEffect, effect.requiresForeground {
                VStack {
                    Spacer()
                    floatingPill(effect: effect)
                        .padding(.bottom, 104)
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.selectedEffect?.id)
            }

            // ── Status toast ──────────────────────────────────────
            if let msg = vm.statusMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
                        .padding(.bottom, 110)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.statusMessage)
            }
        }
        .navigationTitle("Effects")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { stopToolbarItem }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.selectedEffect?.id)
        .animation(.easeInOut(duration: 0.2), value: vm.selectedCategory)
        .onAppear {
            vm.configure(orchestrator: orchestrator)
        }
        // Sync card state when an effect is stopped externally (e.g. home page Stop button).
        .onChange(of: orchestrator.activeEffectEntries) { _, newEntries in
            vm.syncWithOrchestrator(entries: newEntries)
        }
    }

    // MARK: - Background

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            // Glow from selected effect accent
            if let effect = vm.selectedEffect {
                Circle()
                    .fill(RadialGradient(
                        colors: [effect.accentColor.opacity(0.25), .clear],
                        center: .center, startRadius: 0, endRadius: 240))
                    .frame(width: 400)
                    .offset(x: 80, y: -180)
                    .blur(radius: 30)
                    .animation(.easeInOut(duration: 0.6), value: effect.id)
            }
            Circle()
                .fill(RadialGradient(
                    colors: [purple.opacity(0.10), .clear],
                    center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 280)
                .offset(x: -120, y: 200)
                .blur(radius: 24)
        }
        .ignoresSafeArea()
    }

    // MARK: - Running Banner

    private func runningBanner(name: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .overlay(Circle().fill(.green.opacity(0.4)).frame(width: 16))
            Text("'\(name)' is running")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            BeatChipButton(
                capabilities: .global,
                binding: Binding(get: { vm.beatBinding }, set: { vm.beatBinding = $0 }),
                compact: true
            )
            Text("Live")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.green.opacity(0.15)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.green.opacity(0.25), lineWidth: 1)))
    }

    // MARK: - Room Selector

    private var roomSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                roomChip(id: nil, name: "All Rooms", icon: "house.fill")

                ForEach(rooms, id: \.id) { room in
                    roomChip(id: room.id,
                             name: room.name,
                             icon: archetypeIcon(room.archetype))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }

    private func roomChip(id: String?, name: String, icon: String) -> some View {
        let isSelected = vm.selectedRoom?.id == id || (id == nil && vm.selectedRoom == nil)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                vm.selectedRoom = id == nil ? nil : rooms.first(where: { $0.id == id })
            }
            HapticManager.shared.light()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? amber : Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        HStack(spacing: 8) {
            categoryChip(cat: nil, label: "All", icon: "square.grid.2x2.fill")
            ForEach(EffectCategory.allCases) { cat in
                categoryChip(cat: cat, label: cat.rawValue, icon: cat.icon)
            }
        }
    }

    private func categoryChip(cat: EffectCategory?, label: String, icon: String) -> some View {
        let isSelected = vm.selectedCategory == cat
        return Button {
            withAnimation { vm.selectedCategory = cat }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? amber : .white.opacity(0.55))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? amber.opacity(0.15) : .white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(isSelected ? amber.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Effect Grid

    private var effectGrid: some View {
        // Read activeEffectEntries + allRooms here so SwiftUI's @Observable tracking
        // re-renders cards whenever any room's effect changes.
        let entries    = orchestrator.activeEffectEntries
        let allRoomIDs = Set(orchestrator.allRooms.compactMap { $0.groupedLightID != nil ? $0.id : nil })
        return LazyVGrid(columns: gridColumns, spacing: 14) {
            ForEach(vm.filteredEffects) { effect in
                // isSelected = two-signal combination:
                //   1. activeEffectEntries  — persistent truth (cross-room, survives room switches)
                //   2. vm.selectedEffect    — optimistic indicator for the CURRENT room so the
                //      card lights up instantly on tap (before the async activate() finishes)
                //
                // All Rooms uses entries-only subset check (no optimistic fallback) because
                // vm.selectedEffect alone can't confirm ALL rooms have the effect.
                let activeRoomIDs = Set(entries.filter { $0.effectID == effect.id }.map { $0.id })
                let isActive: Bool = {
                    if let room = vm.selectedRoom {
                        // Specific room: entry exists OR effect is currently being selected/applied
                        return activeRoomIDs.contains(room.id)
                            || vm.selectedEffect?.id == effect.id
                    } else {
                        // All Rooms: only selected when EVERY room with lights has the effect
                        return !allRoomIDs.isEmpty && allRoomIDs.isSubset(of: activeRoomIDs)
                    }
                }()
                EffectCard(effect: effect,
                           isSelected: isActive,
                           isRunning:  vm.isRunning && vm.runningEffectName == effect.name,
                           coverageLabel: {
                               // "4 of 6" only when the room PARTIALLY supports
                               // a firmware effect; full support needs no badge.
                               guard case .bridgeNative = effect.strategy,
                                     let cov = vm.effectCoverage[effect.id],
                                     !cov.isFull else { return nil }
                               return cov.isEmpty ? "not supported here" : "\(cov.label) lights"
                           }())
                {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        if isActive {
                            vm.deselect(effectID: effect.id)
                        } else {
                            vm.select(effect)
                            if !effect.requiresForeground {
                                Task { await vm.activate() }
                            }
                        }
                    }
                    HapticManager.shared.medium()
                }
            }
        }
    }

    // MARK: - Floating Pill (app-driven effects)

    private func floatingPill(effect: HueEffect) -> some View {
        HStack(spacing: 14) {
            if vm.isRunning && vm.runningEffectName == effect.name {
                // Stop button
                Button { Task { await vm.stop() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                        Text("Stop \(effect.name)").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Capsule().fill(.red.opacity(0.85)))
                    .shadow(color: .red.opacity(0.4), radius: 12, x: 0, y: 4)
                }
                .buttonStyle(.plain)
            } else {
                // Start button
                Button {
                    HapticManager.shared.heavy()
                    Task { await vm.activate() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                        Text("Start \(effect.name)").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Capsule().fill(effect.accentColor))
                    .shadow(color: effect.accentColor.opacity(0.5), radius: 14, x: 0, y: 5)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vm.isRunning)
    }


    @ToolbarContentBuilder
    private var stopToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { useWideCards.toggle() }
                HapticManager.shared.light()
            } label: {
                Image(systemName: useWideCards ? "rectangle.grid.1x2.fill" : "square.grid.2x2")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        // Save preset — only shown when an effect is selected & configured
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.selectedEffect != nil {
                Button {
                    presetInputName = vm.selectedEffect?.name ?? ""
                    showSaveAlert   = true
                    HapticManager.shared.light()
                } label: {
                    Image(systemName: "bookmark")
                        .foregroundStyle(amber.opacity(0.9))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.isRunning {
                Button {
                    Task { await vm.stop() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 12))
                        Text("Stop").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.red.opacity(0.15)))
                }
            }
        }
    }

    // MARK: - My Presets Row

    private var myPresetsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MY PRESETS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presetsStore.presets) { preset in
                        presetChip(preset)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }

    private func presetChip(_ preset: SavedEffectPreset) -> some View {
        let baseEffect = EffectLibrary.all.first { $0.id == preset.baseEffectID }
        let accentCol  = baseEffect?.accentColor ?? amber
        return Button {
            HapticManager.shared.medium()
            Task { await vm.loadPreset(preset) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: baseEffect?.icon ?? "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentCol)
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(.white.opacity(0.09))
                    .overlay(Capsule().strokeBorder(accentCol.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                presetInputName      = preset.name
                presetToRename       = preset
                showRenamePresetAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                presetToDelete       = preset
                showDeletePresetAlert = true
            } label: {
                Label("Delete Preset", systemImage: "trash")
            }
        }
    }


    // MARK: - Helpers

    private func archetypeIcon(_ archetype: String?) -> String {
        switch archetype {
        case "living_room":  return "sofa.fill"
        case "bedroom":      return "bed.double.fill"
        case "kitchen":      return "refrigerator.fill"
        case "bathroom":     return "shower.fill"
        case "office":       return "desktopcomputer"
        case "gym":          return "dumbbell.fill"
        case "hallway":      return "door.left.hand.open"
        case "outdoor":      return "leaf.fill"
        case "dining_room":  return "fork.knife"
        case "garage":       return "car.fill"
        default:             return "lightbulb.fill"
        }
    }
}

// MARK: - EffectCard

struct EffectCard: View {
    let effect:     HueEffect
    let isSelected: Bool
    let isRunning:  Bool
    var coverageLabel: String? = nil   // "4 of 6 lights" when partial
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {

                // ── Icon ──────────────────────────────────────────────────
                ZStack {
                    Circle()
                        .fill(effect.accentColor.opacity(isSelected ? 0.30 : 0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: effect.icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(effect.accentColor)
                        .symbolEffect(.pulse, isActive: isRunning)
                }

                // ── Text ──────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(effect.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let coverageLabel {
                            Text(coverageLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.08)))
                                .lineLimit(1)
                        }
                    }
                    Text(effect.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                Spacer()

                // ── Right: foreground indicator + running + play ───────────
                HStack(spacing: 6) {
                    if effect.requiresForeground {
                        Image(systemName: "iphone")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    if isRunning {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    Image(systemName: isRunning ? "play.circle.fill" : "play.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            isRunning   ? effect.accentColor :
                            isSelected  ? effect.accentColor.opacity(0.6) :
                                          .white.opacity(0.28)
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected
                          ? effect.accentColor.opacity(0.13)
                          : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                isSelected ? effect.accentColor.opacity(0.55) : Color.white.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .shadow(color: isSelected ? effect.accentColor.opacity(0.25) : .clear,
                    radius: 12, x: 0, y: 4)
        }
        .buttonStyle(ScaleButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - ScaleButtonStyle (reused)
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
