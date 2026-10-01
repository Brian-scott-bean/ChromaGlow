// AutomationsView.swift
// ChromaGlow — Automations (Luminous).
//
// Two kinds of "light that runs itself", told apart honestly: the schedules
// ChromaGlow keeps on this phone (create, edit, switch, delete), and the
// automations that live on the bridge (made in the Philips Hue app; switch
// them on or off here). Pushed from More.

import SwiftUI
import SwiftData

// MARK: - AutomationsView

struct AutomationsView: View {

    @State private var vm = AutomationsViewModel()
    @State private var showLog         = false
    @State private var showCreate      = false
    @State private var editingSchedule:   AppAutomation? = nil  // non-nil → edit sheet open
    @State private var longPressedSchedule: AppAutomation? = nil // non-nil → confirmation dialog
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \AppAutomation.createdAt, order: .forward)
    private var appAutomations: [AppAutomation]

    /// Schedules glow violet: the colour of things that happen on their own.
    private let scheduleTint = LuminousPalette.violet

    var body: some View {
        Group {
            if vm.isLoading && vm.automations.isEmpty && appAutomations.isEmpty {
                loadingView
            } else if let error = vm.errorMessage, vm.automations.isEmpty, appAutomations.isEmpty {
                errorView(error)
            } else {
                automationsList
            }
        }
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog)      { logSheet }
        .sheet(isPresented: $showCreate)   { CreateAutomationView() }
        .sheet(item: $editingSchedule)     { auto in CreateAutomationView(editing: auto) }
        .confirmationDialog(
            longPressedSchedule?.name ?? "",
            isPresented: Binding(
                get: { longPressedSchedule != nil },
                set: { if !$0 { longPressedSchedule = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Edit") {
                editingSchedule = longPressedSchedule
                longPressedSchedule = nil
            }
            Button("Delete", role: .destructive) {
                if let auto = longPressedSchedule {
                    AutomationScheduler.shared.cancel(auto)
                    modelContext.delete(auto)
                }
                longPressedSchedule = nil
            }
            Button("Cancel", role: .cancel) { longPressedSchedule = nil }
        }
        .task {
            // Inject orchestrator clients each time the screen appears. In
            // demo mode allBridgeIDs is empty — loadAutomations() checks
            // isDemoMode first.
            vm.configure(bridgeIDs: orchestrator.allBridgeIDs, orchestrator: orchestrator)
            await vm.loadAutomations()
        }
        .refreshable { await vm.loadAutomations() }
    }

    // MARK: - List

    private var automationsList: some View {
        LuminousPage(title: "Automations",
                     eyebrow: "Light that runs itself",
                     eyebrowSymbol: "bolt.fill",
                     tint: scheduleTint,
                     subtitle: "Your schedules, and the automations your bridge keeps.",
                     ambience: [scheduleTint, LuminousPalette.cyan]) {
            summaryChips
            mySchedulesSection
            bridgeSection
        }
    }

    private var summaryChips: some View {
        let scheduleOn = appAutomations.filter(\.isEnabled).count
        let bridgeOn = vm.automations.filter(\.enabled).count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !appAutomations.isEmpty {
                    LuminousStateChip(text: "\(scheduleOn) of \(appAutomations.count) schedules on",
                                      dot: scheduleOn > 0 ? scheduleTint : LuminousPalette.inkSecondary,
                                      glowing: scheduleOn > 0)
                }
                LuminousStateChip(text: bridgeOn == 0
                                    ? "\(vm.automations.count) on your bridge · all off"
                                    : "\(bridgeOn) of \(vm.automations.count) on your bridge",
                                  dot: bridgeOn > 0 ? LuminousPalette.cyan : LuminousPalette.inkSecondary,
                                  glowing: bridgeOn > 0)
            }
        }
        .scrollClipDisabled()
    }

    // ── My Schedules ──────────────────────────────

    private var mySchedulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousSectionHeader(title: "My schedules",
                                  subtitle: "Kept by ChromaGlow on this phone.",
                                  symbol: "clock.fill", tint: scheduleTint) {
                // Empty, the empty state carries the one New button.
                if !appAutomations.isEmpty {
                    LuminousPrimaryButton(title: "New", symbol: "plus", compact: true) { newSchedule() }
                        .accessibilityLabel("New schedule")
                }
            }
            if appAutomations.isEmpty {
                LuminousEmptyState(symbol: "calendar.badge.plus",
                                   title: "No schedules yet",
                                   message: "Wake up to Energize, wind down with Relax — pick a time and the days, and it's set.",
                                   actionTitle: "New schedule",
                                   action: newSchedule)
            } else {
                LuminousGroup {
                    ForEach(Array(appAutomations.enumerated()), id: \.element.id) { idx, automation in
                        appAutomationRow(automation)
                        if idx < appAutomations.count - 1 { LuminousRowDivider() }
                    }
                }
            }
        }
    }

    private func newSchedule() {
        Task {
            _ = await AutomationScheduler.shared.requestPermission()
            showCreate = true
        }
    }

    private func appAutomationRow(_ automation: AppAutomation) -> some View {
        HStack(spacing: 14) {
            LuminousIconBadge(symbol: automation.action.icon, tint: scheduleTint, size: 36, lit: automation.isEnabled)

            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(automation.isEnabled ? LuminousPalette.ink : LuminousPalette.inkSecondary)
                    .lineLimit(1)
                Text("\(automation.timeLabel) · \(automation.daysLabel)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(LuminousPalette.inkSecondary)
                // A schedule acts on every room — the row used to give no
                // hint whether 8 AM "Energize" touched the whole house (M-11).
                Label("\(automation.action.displayName) · every room", systemImage: "house.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LuminousPalette.inkTertiary)
                    .lineLimit(1)

                // Static signature strip for dynamic effects (Automations is
                // a calm surface — no animation by design). Mood/gradual
                // effects have no signature and show none.
                if case .effect(let effectID) = automation.action,
                   let pattern = StudioCardCanvas.signaturePattern(forCardID: effectID) {
                    PatternStripView(
                        pattern: pattern,
                        accent: EffectLibrary.all.first(where: { $0.id == effectID })?.accentColor ?? scheduleTint,
                        animated: false
                    )
                    .padding(.top, 3)
                    .frame(maxWidth: 110)
                    .opacity(automation.isEnabled ? 1 : 0.4)
                }
            }

            Spacer(minLength: 0)

            // ··· — Edit / Delete
            Button {
                HapticManager.shared.light()
                longPressedSchedule = automation
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit or delete \(automation.name)")

            Toggle(automation.name, isOn: Binding(
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
            .labelsHidden()
            .tint(LuminousPalette.cyan)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3), value: automation.isEnabled)
    }

    // ── Bridge automations ────────────────────────

    @ViewBuilder
    private var bridgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousSectionHeader(title: "On your bridge",
                                  subtitle: "Made in the Philips Hue app. Switch them on or off here.",
                                  symbol: "network", tint: LuminousPalette.cyan) {
                if vm.isLoading {
                    ProgressView().tint(LuminousPalette.ink).scaleEffect(0.8)
                }
            }
            if vm.isLoading && vm.automations.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(LuminousPalette.cyan)
                    Text("Reading your bridge…")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .luminousGlass()
            } else if let error = vm.errorMessage, vm.automations.isEmpty {
                LuminousEmptyState(symbol: "bolt.trianglebadge.exclamationmark.fill",
                                   title: "Couldn't read the bridge",
                                   message: error,
                                   actionTitle: "Try again",
                                   action: { Task { await vm.loadAutomations() } })
            } else if vm.automations.isEmpty {
                LuminousEmptyState(symbol: "bolt.slash.fill",
                                   title: "No automations found",
                                   message: "Create automations in the Philips Hue app — they'll appear here.")
            } else {
                ForEach(groupedAutomations(), id: \.0.rawValue) { (category, items) in
                    automationGroup(category: category, items: items)
                }
            }
        }
    }

    private func automationGroup(
        category: AutomationDisplayItem.AutomationCategory,
        items: [AutomationDisplayItem]
    ) -> some View {
        LuminousGroup(title: "\(category.rawValue) · \(items.count)") {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                AutomationRow(item: item, iconColor: iconColor(category)) {
                    vm.toggle(item)
                }
                if idx < items.count - 1 { LuminousRowDivider() }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showLog.toggle() } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(LuminousPalette.ink.opacity(0.75))
            }
            .accessibilityLabel("Automations console")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.isLoading {
                ProgressView().progressViewStyle(.circular).tint(LuminousPalette.ink).scaleEffect(0.8)
            } else {
                Button { Task { await vm.loadAutomations() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                .accessibilityLabel("Refresh")
            }
        }
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView().progressViewStyle(.circular).tint(scheduleTint).scaleEffect(1.4)
            Text("Reading your automations…")
                .font(.subheadline)
                .foregroundStyle(LuminousPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LuminousAmbience(colors: [scheduleTint], intensity: 0.6) }
        .luminousPageChrome(title: "Automations")
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            LuminousEmptyState(symbol: "bolt.trianglebadge.exclamationmark.fill",
                               title: "Couldn't read automations",
                               message: message,
                               actionTitle: "Try again",
                               action: { Task { await vm.loadAutomations() } })
        }
        .padding(.horizontal, HueSpacing.screenH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LuminousAmbience(colors: [LuminousPalette.amber], intensity: 0.6) }
        .luminousPageChrome(title: "Automations")
    }

    // MARK: - Log Sheet

    private var logSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LuminousPalette.ink.opacity(0.8))
                                .id(idx)
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(LuminousPalette.void)
            .navigationTitle("Automations Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .luminousSheet()
    }

    // MARK: - Helpers

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
        AutomationRow.tint(for: category)
    }
}

// MARK: - AutomationRow

/// One bridge automation: its glowing category icon, name, status, switch.
/// Self-padded like `LuminousRow`, so it drops straight into a
/// `LuminousGroup` (Automations, and a room's schedules).
struct AutomationRow: View {

    let item:      AutomationDisplayItem
    let iconColor: Color
    let onToggle:  () -> Void

    var body: some View {
        HStack(spacing: 14) {
            LuminousIconBadge(symbol: item.category.icon, tint: iconColor, size: 36, lit: item.enabled)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.enabled ? LuminousPalette.ink : LuminousPalette.inkSecondary)
                    .lineLimit(1)
                if let status = item.status, !status.isEmpty {
                    Text(status.capitalized)
                        .font(.footnote)
                        .foregroundStyle(statusColor(status))
                } else {
                    Text(item.category.rawValue)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
            }

            Spacer(minLength: 0)

            Toggle(item.name, isOn: Binding(
                get: { item.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(LuminousPalette.cyan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3), value: item.enabled)
    }

    private func statusColor(_ s: String) -> Color {
        switch s.lowercased() {
        case "running":  return LuminousPalette.live
        case "waiting":  return LuminousPalette.amber
        case "stopped":  return LuminousPalette.danger
        default:         return LuminousPalette.inkSecondary
        }
    }

    /// The glow each kind of bridge automation carries.
    static func tint(for category: AutomationDisplayItem.AutomationCategory) -> Color {
        switch category.color {
        case "orange":  return Color(hex: "#FF9F5C")
        case "indigo":  return Color(hex: "#7C7BFF")
        case "yellow":  return Color(hex: "#FFD36B")
        case "blue":    return Color(hex: "#6699FF")
        case "teal":    return Color(hex: "#40D9BF")
        case "purple":  return LuminousPalette.violet
        default:        return LuminousPalette.cyan
        }
    }
}
