// CreateAutomationView.swift
// ChromaGlow — create or edit a schedule (Luminous sheet).
//
// Name, time, the days it repeats, and what it does: one of the four moods
// (drawn as the light each makes) or an effect. The honesty line under the
// time stays: a local notification can't run code on silent delivery.

import SwiftUI
import SwiftData

// MARK: - CreateAutomationView

struct CreateAutomationView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss)      private var dismiss
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    // Editing existing or creating new
    var editing: AppAutomation? = nil

    // MARK: Form State
    @State private var name:         String      = ""
    @State private var time:         Date        = Calendar.current.nextDate(
                                                        after: Date(),
                                                        matching: DateComponents(hour: 8, minute: 0),
                                                        matchingPolicy: .nextTime) ?? Date()
    @State private var weekdays:     Set<Int>    = [2, 3, 4, 5, 6]
    @State private var actionType:   ActionTab   = .preset
    @State private var selectedPreset: String    = "energize"
    @State private var selectedEffect: String    = "colorloop"
    @State private var isSaving:     Bool        = false

    enum ActionTab: String, CaseIterable {
        case preset = "Preset"
        case effect = "Effect"
    }

    private let allWeekdays: [(Int, String, String)] = [
        (1, "S", "Sunday"), (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"),
        (5, "T", "Thursday"), (6, "F", "Friday"), (7, "S", "Saturday")
    ]

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    LuminousScreenTitle(title: editing == nil ? "New schedule" : "Edit schedule",
                                        eyebrow: "Automations",
                                        eyebrowSymbol: "clock.fill",
                                        eyebrowTint: LuminousPalette.violet,
                                        subtitle: "A time, the days, and the light it brings.")
                    LuminousTextField(caption: "Name", placeholder: "e.g. Good Morning", text: $name)
                    timeSection
                    daysSection
                    actionSection
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .background { LuminousAmbience(colors: [LuminousPalette.violet, actionGlow], intensity: 0.7) }
            .navigationTitle(editing == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().tint(LuminousPalette.ink)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .foregroundStyle(LuminousPalette.cyan)
                    .disabled(weekdays.isEmpty || isSaving)
                }
            }
        }
        .luminousSheet()
        .onAppear(perform: populateIfEditing)
    }

    /// The colour of what the schedule will do — the background leans to it.
    private var actionGlow: Color {
        if actionType == .preset, let preset = LightingPreset.find(selectedPreset) {
            return preset.luminousColor
        }
        return EffectLibrary.all.first(where: { $0.id == selectedEffect })?.accentColor ?? LuminousPalette.cyan
    }

    // MARK: - Time

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: "Time").padding(.horizontal, 6)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .luminousGlass(radius: 20)
            // Honesty: a local notification can't run code on silent
            // delivery — the schedule fires only via a tap or a live app.
            Text("Runs when you tap its reminder, or right away if the app is open at that time.")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Days

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "Repeat").padding(.horizontal, 6)
            HStack(spacing: 6) {
                ForEach(allWeekdays, id: \.0) { day in
                    let selected = weekdays.contains(day.0)
                    Button {
                        HapticManager.shared.selection()
                        if selected { weekdays.remove(day.0) } else { weekdays.insert(day.0) }
                    } label: {
                        Text(day.1)
                            .font(.system(.subheadline, design: .rounded).weight(.heavy))
                            .foregroundStyle(selected ? LuminousPalette.void : LuminousPalette.ink.opacity(0.7))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(selected ? AnyShapeStyle(LuminousPalette.signalGradient)
                                                               : AnyShapeStyle(Color.white.opacity(0.07))))
                            .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.35 : 0.1), lineWidth: 1))
                            .shadow(color: selected ? LuminousPalette.cyan.opacity(0.45) : .clear, radius: 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LuminousPressStyle(scale: 0.9))
                    .accessibilityLabel(day.2)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                }
            }
            if weekdays.isEmpty {
                Text("Select at least one day")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LuminousPalette.danger)
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousEyebrow(text: "What it does").padding(.horizontal, 6)
            LuminousSegmented(options: ActionTab.allCases, selection: $actionType,
                              title: { $0 == .preset ? "Mood" : "Effect" },
                              symbol: { $0 == .preset ? "sun.max.fill" : "sparkles" },
                              accessibilityLabel: "Action type")
            // Say where it lands before Save — there is no room picker, and
            // a schedule changes every room on every bridge (M-11).
            Label("Runs in every room, on every bridge.", systemImage: "house.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(LuminousPalette.inkSecondary)
                .padding(.horizontal, 6)
                .accessibilityLabel("This schedule runs in every room, on every bridge")
            if actionType == .preset {
                presetPicker
            } else {
                effectPicker
            }
        }
    }

    private var presetPicker: some View {
        LuminousGroup {
            ForEach(Array(LightingPreset.all.enumerated()), id: \.element.id) { idx, preset in
                let selected = selectedPreset == preset.id
                Button {
                    HapticManager.shared.selection()
                    selectedPreset = preset.id
                } label: {
                    HStack(spacing: 14) {
                        LuminousPaletteOrbs(colors: [preset.luminousColor], count: 1, height: 36)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(preset.luminousColor)
                                Text(preset.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(LuminousPalette.ink)
                            }
                            Text("\(BrightnessDisplay.percent(preset.brightness))% · \(HueColorUtils.kelvin(from: preset.mirek))K")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(LuminousPalette.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        selectionMark(selected, tint: LuminousPalette.cyan)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 60)
                    .background(selected ? LuminousPalette.cyan.opacity(0.08) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LuminousRowButtonStyle())
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                if idx < LightingPreset.all.count - 1 { LuminousRowDivider() }
            }
        }
    }

    private var effectPicker: some View {
        let effects = EffectLibrary.all.filter { !$0.requiresForeground }
        return LuminousGroup {
            ForEach(Array(effects.enumerated()), id: \.element.id) { idx, effect in
                let selected = selectedEffect == effect.id
                Button {
                    HapticManager.shared.selection()
                    selectedEffect = effect.id
                } label: {
                    HStack(spacing: 14) {
                        LuminousIconBadge(symbol: effect.icon, tint: effect.accentColor, size: 36, lit: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(LuminousPalette.ink)
                            Text(effect.tagline)
                                .font(.footnote)
                                .foregroundStyle(LuminousPalette.inkSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        selectionMark(selected, tint: effect.accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 60)
                    .background(selected ? effect.accentColor.opacity(0.1) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LuminousRowButtonStyle())
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
                if idx < effects.count - 1 { LuminousRowDivider() }
            }
        }
    }

    private func selectionMark(_ selected: Bool, tint: Color) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(selected ? tint : LuminousPalette.inkTertiary)
            .shadow(color: selected ? tint.opacity(0.6) : .clear, radius: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private func populateIfEditing() {
        guard let a = editing else { return }
        name = a.name
        var comps   = DateComponents()
        comps.hour  = a.hour
        comps.minute = a.minute
        time        = Calendar.current.date(from: comps) ?? Date()
        weekdays    = Set(a.weekdays)
        switch a.action {
        case .preset(let id): actionType = .preset; selectedPreset = id
        case .effect(let id): actionType = .effect; selectedEffect = id
        }
    }

    private func save() {
        let comps  = Calendar.current.dateComponents([.hour, .minute], from: time)
        let action: AutomationAction = actionType == .preset
            ? .preset(selectedPreset)
            : .effect(selectedEffect)
        let safeName = name.trimmingCharacters(in: .whitespaces)
                           .isEmpty ? action.displayName + " " + formattedTime() : name

        if let a = editing {
            a.name     = safeName
            a.hour     = comps.hour ?? 8
            a.minute   = comps.minute ?? 0
            a.weekdays = Array(weekdays).sorted()
            a.action   = action
            AutomationScheduler.shared.schedule(a)
        } else {
            let a = AppAutomation(
                name:     safeName,
                hour:     comps.hour ?? 8,
                minute:   comps.minute ?? 0,
                weekdays: Array(weekdays).sorted(),
                action:   action
            )
            modelContext.insert(a)
            AutomationScheduler.shared.schedule(a)
        }

        dismiss()
    }

    private func formattedTime() -> String {
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .none
        return fmt.string(from: time)
    }
}
