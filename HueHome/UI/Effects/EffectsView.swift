// EffectsView.swift
// HueHome Pro — Effects Tab
//
// Main Effects tab: room selector, category filter, 2-column effect grid,
// expandable controls panel, and Activate button.

import SwiftUI

// MARK: - EffectsView

struct EffectsView: View {

    @State private var vm = EffectsViewModel()
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    // Accent colours
    private let amber  = Color(red: 1.0,  green: 0.76, blue: 0.20)
    private let purple = Color(red: 0.55, green: 0.35, blue: 1.00)
    private let teal   = Color(red: 0.25, green: 0.85, blue: 0.75)
    private let pink   = Color(red: 1.0,  green: 0.30, blue: 0.55)

    // Room list from orchestrator for the top selector
    private var rooms: [RoomDisplayItem] { orchestrator.allRooms }

    var body: some View {
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
        }
        .navigationTitle("Effects")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar { stopToolbarItem }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.selectedEffect?.id)
        .animation(.easeInOut(duration: 0.2), value: vm.selectedCategory)
        .onAppear {
            vm.configure(orchestrator: orchestrator)
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
        let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: cols, spacing: 14) {
            ForEach(vm.filteredEffects) { effect in
                EffectCard(effect: effect,
                           isSelected: vm.selectedEffect?.id == effect.id,
                           isRunning:  vm.isRunning && vm.runningEffectName == effect.name)
                {
                    print("[EffectCard] tapped: \(effect.name)")
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        if vm.selectedEffect?.id == effect.id {
                            vm.selectedEffect = nil
                        } else {
                            vm.select(effect)
                        }
                    }
                    HapticManager.shared.medium()
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var stopToolbarItem: some ToolbarContent {
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
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(effect.accentColor.opacity(isSelected ? 0.30 : 0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: effect.icon)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(effect.accentColor)
                            .symbolEffect(.pulse, isActive: isRunning)
                    }
                    Spacer()
                    if effect.requiresForeground {
                        Image(systemName: "iphone")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    if isRunning {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(effect.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(effect.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }   // end body
}   // end EffectCard

// MARK: - ScaleButtonStyle (reused)
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
