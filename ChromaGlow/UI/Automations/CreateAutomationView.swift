// CreateAutomationView.swift
// ChromaGlow — Sheet for creating or editing an AppAutomation.

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

    private let allWeekdays: [(Int, String)] = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")
    ]

    private let presets: [(id: String, name: String, icon: String)] = [
        ("energize", "Energize", "bolt.fill"),
        ("read",     "Read",     "book.fill"),
        ("relax",    "Relax",    "moon.stars.fill"),
        ("sleep",    "Sleep",    "zzz"),
    ]

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.10).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        nameField
                        timeSection
                        daysSection
                        actionSection
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            .navigationTitle(editing == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(weekdays.isEmpty || isSaving)
                }
            }
        }
        .onAppear(perform: populateIfEditing)
    }

    // MARK: - Name Field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Name")
            TextField("e.g. Good Morning", text: $name)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Time Section

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Time")
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
        }
    }

    // MARK: - Days Section

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Repeat")
            HStack(spacing: 8) {
                ForEach(allWeekdays, id: \.0) { day in
                    let selected = weekdays.contains(day.0)
                    Button {
                        if selected { weekdays.remove(day.0) } else { weekdays.insert(day.0) }
                    } label: {
                        Text(day.1)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .foregroundStyle(selected ? .black : .white.opacity(0.6))
                            .background(Circle().fill(selected ? Color(hue: 0.58, saturation: 0.7, brightness: 1.0) : .white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if weekdays.isEmpty {
                Text("Select at least one day")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Action")
            Picker("Action Type", selection: $actionType) {
                ForEach(ActionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            if actionType == .preset {
                presetPicker
            } else {
                effectPicker
            }
        }
    }

    private var presetPicker: some View {
        VStack(spacing: 8) {
            ForEach(presets, id: \.id) { preset in
                let selected = selectedPreset == preset.id
                Button { selectedPreset = preset.id } label: {
                    HStack(spacing: 14) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selected ? .black : .white.opacity(0.7))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(selected ? .white : .white.opacity(0.1)))
                        Text(preset.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hue: 0.58, saturation: 0.7, brightness: 1.0))
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? .white.opacity(0.12) : .white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? .white.opacity(0.25) : .clear, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var effectPicker: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(EffectLibrary.all.filter { !$0.requiresForeground }) { effect in
                    let selected = selectedEffect == effect.id
                    Button { selectedEffect = effect.id } label: {
                        HStack(spacing: 14) {
                            Image(systemName: effect.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selected ? .black : effect.accentColor)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(selected ? effect.accentColor : effect.accentColor.opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(effect.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                Text(effect.tagline).font(.caption).foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            if selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(effect.accentColor)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(selected ? effect.accentColor.opacity(0.15) : .white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? effect.accentColor.opacity(0.4) : .clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
    }

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
