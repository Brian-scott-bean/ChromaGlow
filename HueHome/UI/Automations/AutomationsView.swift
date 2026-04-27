// AutomationsView.swift
// HueHome Pro — Epic 6
//
// Read/write view of all Bridge automations (behavior_instances).
// Users can enable/disable any automation with a tap.
// Grouped by category (Wake-up, Sleep, Schedule, etc.)
// Pushed onto the navigation stack from the Dashboard toolbar (⚡ button).

import SwiftUI

// MARK: - AutomationsView

struct AutomationsView: View {

    @State private var vm = AutomationsViewModel()
    @State private var showLog = false
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    private let amber  = Color(red: 1.0, green: 0.76, blue: 0.20)
    private let purple = Color(red: 0.55, green: 0.35, blue: 1.00)

    var body: some View {
        ZStack {
            ambientBackground

            Group {
                if vm.isLoading && vm.automations.isEmpty {
                    loadingView
                } else if let error = vm.errorMessage, vm.automations.isEmpty {
                    errorView(error)
                } else {
                    automationsList
                }
            }
        }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .task {
            // Inject orchestrator clients each time the tab appears.
            // For demo mode, orchestrator.allBridgeIDs will be empty — that's fine,
            // AutomationsViewModel.loadAutomations() checks isDemoMode first.
            vm.configure(bridgeIDs: orchestrator.allBridgeIDs, orchestrator: orchestrator)
            await vm.loadAutomations()
        }
        .refreshable { await vm.loadAutomations() }
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
                    colors: [purple.opacity(0.20), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 340)
                .offset(x: 120, y: -180)
                .blur(radius: 20)
            Circle()
                .fill(RadialGradient(
                    colors: [amber.opacity(0.12), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 260)
                .offset(x: -100, y: 140)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Automations List
    // ──────────────────────────────────────────────

    private var automationsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Summary header
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                if vm.automations.isEmpty {
                    emptyState
                } else {
                    // Group by category
                    let groups = groupedAutomations()
                    VStack(spacing: 24) {
                        ForEach(groups, id: \.0.rawValue) { (category, items) in
                            automationGroup(category: category, items: items)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    // ── Summary Header ────────────────────────────

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                let enabledCount = vm.automations.filter(\.enabled).count
                Text(enabledCount == 0
                     ? "All automations off"
                     : "\(enabledCount) active")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(vm.automations.count) automation\(vm.automations.count == 1 ? "" : "s") on Bridge")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            let anyEnabled = vm.automations.contains(where: { $0.enabled })
            Circle()
                .fill(anyEnabled ? purple : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
                .shadow(color: anyEnabled ? purple.opacity(0.9) : .clear, radius: 8)
        }
    }

    // ── Group Section ─────────────────────────────

    private func automationGroup(
        category: AutomationDisplayItem.AutomationCategory,
        items: [AutomationDisplayItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor(category))
                Text(category.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text("(\(items.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
            }

            GlassmorphicCard(isActive: items.contains(where: \.enabled),
                             glowColor: iconColor(category)) {
                VStack(spacing: 0) {
                    let built = automationRows(items: items, category: category)
                    built
                }
            }
        }
    }

    private func automationRows(
        items: [AutomationDisplayItem],
        category: AutomationDisplayItem.AutomationCategory
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                AutomationRow(item: item, iconColor: iconColor(category)) {
                    vm.toggle(item)
                }

                if idx < items.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.07))
                }
            }
        }
    }

    // ── Empty State ───────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text("No automations found")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("Create automations in the Philips Hue app — they'll appear here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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
                Button { Task { await vm.loadAutomations() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Loading / Error
    // ──────────────────────────────────────────────

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().progressViewStyle(.circular).tint(purple).scaleEffect(1.6)
            Text("Loading automations…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadAutomations() } }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Log Sheet
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
            .navigationTitle("Automations Console")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Groups automations by category, preserving a logical order.
    private func groupedAutomations() -> [(AutomationDisplayItem.AutomationCategory, [AutomationDisplayItem])] {
        let order: [AutomationDisplayItem.AutomationCategory] =
            [.wakeUp, .sleep, .circadian, .schedule, .timer, .tapToRun, .other]
        var dict: [AutomationDisplayItem.AutomationCategory: [AutomationDisplayItem]] = [:]
        for item in vm.automations {
            dict[item.category, default: []].append(item)
        }
        return order.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    private func iconColor(_ category: AutomationDisplayItem.AutomationCategory) -> Color {
        switch category.color {
        case "orange":  return .orange
        case "indigo":  return .indigo
        case "yellow":  return amber
        case "blue":    return Color(red: 0.4, green: 0.6, blue: 1.0)
        case "teal":    return .teal
        case "purple":  return purple
        default:        return amber
        }
    }
}

// MARK: - AutomationRow

struct AutomationRow: View {

    let item:      AutomationDisplayItem
    let iconColor: Color
    let onToggle:  () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(item.enabled
                          ? iconColor.opacity(0.18)
                          : Color.white.opacity(0.06))
                    .frame(width: 40, height: 40)
                Image(systemName: item.category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(item.enabled ? iconColor : .white.opacity(0.25))
            }

            // Name + status
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.enabled ? .white : .white.opacity(0.45))
                    .lineLimit(1)

                if let status = item.status, !status.isEmpty {
                    Text(status.capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor(status).opacity(0.75))
                } else {
                    Text(item.category.rawValue)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.30))
                }
            }

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { _ in onToggle() }
            ))
            .tint(iconColor)
            .labelsHidden()
            .scaleEffect(0.85)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .opacity(item.enabled ? 1.0 : 0.72)
        .animation(.spring(response: 0.3), value: item.enabled)
    }

    private func statusColor(_ s: String) -> Color {
        switch s.lowercased() {
        case "running":  return .green
        case "waiting":  return .orange
        case "stopped":  return .red
        default:         return .white
        }
    }
}
