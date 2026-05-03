// AutomationsView.swift
// HueHome Pro — Epic 6
//
// Read/write view of all Bridge automations (behavior_instances).
// Users can enable/disable any automation with a tap.
// Grouped by category (Wake-up, Sleep, Schedule, etc.)
// Pushed onto the navigation stack from the Dashboard toolbar (⚡ button).

import SwiftUI
import SwiftData

// MARK: - AutomationsView

struct AutomationsView: View {

    @State private var vm = AutomationsViewModel()
    @State private var showLog         = false
    @State private var showCreate      = false
    @State private var editingSchedule: AppAutomation? = nil  // non-nil → edit sheet open
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \AppAutomation.createdAt, order: .forward)
    private var appAutomations: [AppAutomation]

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
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog)      { logSheet }
        .sheet(isPresented: $showCreate)   { CreateAutomationView() }
        .sheet(item: $editingSchedule)     { auto in CreateAutomationView(editing: auto) }
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
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                // ── My Schedules (app-side) ────────────────────────
                mySchedulesSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, appAutomations.isEmpty ? 0 : 24)

                // ── Bridge Automations ─────────────────────────────
                if vm.automations.isEmpty {
                    emptyState
                } else {
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

    // ── My Schedules Section ──────────────────────

    private var mySchedulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(amber)
                    Text("MY SCHEDULES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("(\(appAutomations.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                Button {
                    Task {
                        _ = await AutomationScheduler.shared.requestPermission()
                        showCreate = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(amber))
                }
                .buttonStyle(.plain)
            }

            if appAutomations.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.18))
                        Text("No schedules yet — tap New")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.04)))
            } else {
                GlassmorphicCard(isActive: appAutomations.contains(where: \.isEnabled),
                                 glowColor: amber) {
                    VStack(spacing: 0) {
                        ForEach(Array(appAutomations.enumerated()), id: \.element.id) { idx, automation in
                            appAutomationRow(automation)
                            if idx < appAutomations.count - 1 {
                                Divider().background(Color.white.opacity(0.07))
                            }
                        }
                    }
                }
            }
        }
    }

    private func appAutomationRow(_ automation: AppAutomation) -> some View {
        // Toggle lives in an overlay OUTSIDE the contextMenu container.
        // UISwitch has internal gesture recognisers that compete with the long-press
        // that drives .contextMenu — separating the layers eliminates that conflict.
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(automation.isEnabled ? amber.opacity(0.18) : Color.white.opacity(0.06))
                    .frame(width: 40, height: 40)
                Image(systemName: automation.action.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(automation.isEnabled ? amber : .white.opacity(0.25))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(automation.isEnabled ? .white : .white.opacity(0.45))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(automation.timeLabel)
                    Text("·")
                    Text(automation.daysLabel)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
            }

            Spacer()

            // Reserve space so content doesn't shift when overlay Toggle renders
            Color.clear.frame(width: 51, height: 31)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(automation.isEnabled ? 1.0 : 0.7)
        .contextMenu {
            Button {
                editingSchedule = automation
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                AutomationScheduler.shared.cancel(automation)
                modelContext.delete(automation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .overlay(alignment: .trailing) {
            // Toggle sits above the contextMenu layer — handles taps independently
            Toggle("", isOn: Binding(
                get:  { automation.isEnabled },
                set:  { enabled in
                    automation.isEnabled = enabled
                    if enabled {
                        AutomationScheduler.shared.schedule(automation)
                    } else {
                        AutomationScheduler.shared.cancel(automation)
                    }
                }
            ))
            .tint(amber)
            .labelsHidden()
            .scaleEffect(0.85)
        }
        .animation(.spring(response: 0.3), value: automation.isEnabled)
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
        // Note: contextMenu reserved for Edit + Delete when bridge automation CRUD is built
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
