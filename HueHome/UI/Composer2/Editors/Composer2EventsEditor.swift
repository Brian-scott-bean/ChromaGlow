// Composer2EventsEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The event generator's controls — Thunderstorm's lightning is one setting
// of these; sparkles and eerie flashes are others.

import SwiftUI

struct Composer2EventsEditorContent: View {
    let document: Composer2Document

    private var events: Composer2EventSpec? { document.selectedLayer.events }
    private let delayRange: ClosedRange<Double> = 0.5...120

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Events", subtitle: "Something happens every so often — to some lights, for a moment.") {
                StageToggleRow(title: "Enable events", isOn: Binding(
                    get: { events != nil },
                    set: { on in
                        HapticManager.shared.selection()
                        document.setEvents(enabled: on, default: Composer2EventsEditorContent.defaultSpec)
                    }))
                if let spec = events {
                    Text(Composer2Copy.summary(events: spec))
                        .font(HueFont.captionMedium)
                        .foregroundStyle(Composer2Theme.ink.opacity(0.8))
                }
            }
            if events != nil {
                Composer2EditorSection(title: "Timing") {
                    Composer2ChipRow(title: "Interval", options: [
                        ("Random", Composer2EventSpec.Timing.random, "dice"),
                        ("Fixed", .fixed, "metronome")
                    ], selection: eventBinding(\.timing))
                    if events?.timing == .fixed {
                        Composer2SliderRow(title: "Every", value: logBinding(\.interval), range: 0...1,
                                           format: { composer2Seconds(document.logSeconds($0, range: delayRange)) })
                    } else {
                        Composer2SliderRow(title: "Minimum delay", value: logBinding(\.minDelay), range: 0...1,
                                           format: { composer2Seconds(document.logSeconds($0, range: delayRange)) })
                        Composer2SliderRow(title: "Maximum delay", value: logBinding(\.maxDelay), range: 0...1,
                                           format: { composer2Seconds(document.logSeconds($0, range: delayRange)) })
                    }
                    Composer2SliderRow(title: "Chance", value: eventBinding(\.probability), range: 0...1)
                    Composer2SliderRow(title: "Cooldown", value: eventBinding(\.cooldown), range: 0...60,
                                       format: { composer2Seconds($0) })
                }
                Composer2EditorSection(title: "Each event") {
                    Composer2StepperRow(title: "Flashes, at least", value: eventBinding(\.burstMin), range: 1...12)
                    Composer2StepperRow(title: "Flashes, at most", value: eventBinding(\.burstMax), range: 1...12)
                    Composer2SliderRow(title: "Gap between flashes", value: eventBinding(\.spacingMax), range: 0.34...3,
                                       format: { composer2Seconds($0) })
                    Composer2SliderRow(title: "Flash length", value: eventBinding(\.durationMax), range: 0.02...2,
                                       format: { composer2Seconds($0) })
                    Composer2SliderRow(title: "Fade out", value: eventBinding(\.decaySeconds), range: 0.05...5,
                                       format: { composer2Seconds($0) })
                    Composer2SliderRow(title: "Brightness, up to", value: eventBinding(\.intensityMax), range: 0...1)
                    Composer2SliderRow(title: "Brightness, at least", value: eventBinding(\.intensityMin), range: 0...1)
                    Composer2SliderRow(title: "Rare major strikes", value: eventBinding(\.majorProbability), range: 0...1)
                }
                Composer2EditorSection(title: "Where") {
                    Composer2ChipRow(title: "Lights hit", options: [
                        ("All", Composer2EventSpec.Targeting.all, "rectangle.grid.2x2"),
                        ("A few at random", .randomCount, "dice"),
                        ("Nearby", .spatialBiased, "scope")
                    ], selection: eventBinding(\.targeting))
                    if events?.targeting == .randomCount {
                        Composer2StepperRow(title: "How many", value: eventBinding(\.targetCount), range: 1...20)
                    }
                    if events?.targeting == .spatialBiased {
                        Composer2SliderRow(title: "Spatial randomness", value: Binding(
                            get: { 1 - (events?.spatialBias ?? 0.5) },
                            set: { v in document.editSelectedLayer { $0.events?.spatialBias = 1 - v } }
                        ), range: 0...1)
                    }
                }
                Composer2EditorSection(title: "Effect") {
                    modulationToggle("Brightness flash", .brightness)
                    modulationToggle("Colour flash", .color)
                    modulationToggle("Kick the motion", .motion)
                    if events?.modulates.contains(.motion) == true {
                        Composer2SliderRow(title: "Kick strength", value: eventBinding(\.motionKick), range: -1...1,
                                           format: { String(format: "%+.2f", $0) })
                    }
                }
            }
        }
    }

    static var defaultSpec: Composer2EventSpec {
        Composer2EventSpec(timing: .random, minDelay: 4, maxDelay: 12, probability: 0.8, burstMin: 1, burstMax: 3,
                           spacingMin: BeatMath.FlashSafety.minOnsetLedgerPeriod, spacingMax: 0.55,
                           durationMin: 0.06, durationMax: 0.14, decaySeconds: 0.35,
                           intensityMin: 0.6, intensityMax: 1, targeting: .spatialBiased, spatialBias: 0.5,
                           modulates: [.brightness, .color], color: Composer2XY(x: 0.27, y: 0.28))
    }

    private func eventBinding<T>(_ keyPath: WritableKeyPath<Composer2EventSpec, T>) -> Binding<T> {
        Binding(
            get: { (events ?? Composer2EventsEditorContent.defaultSpec)[keyPath: keyPath] },
            set: { value in document.editSelectedLayer { $0.events?[keyPath: keyPath] = value } }
        )
    }

    private func logBinding(_ keyPath: WritableKeyPath<Composer2EventSpec, Double>) -> Binding<Double> {
        let lo = log(delayRange.lowerBound), hi = log(delayRange.upperBound)
        return Binding(
            get: {
                let v = Composer2Math.clamp((events ?? Composer2EventsEditorContent.defaultSpec)[keyPath: keyPath], delayRange.lowerBound, delayRange.upperBound)
                return (log(v) - lo) / (hi - lo)
            },
            set: { t in
                let v = exp(lo + Composer2Math.clamp01(t) * (hi - lo))
                document.editSelectedLayer { $0.events?[keyPath: keyPath] = v }
            }
        )
    }

    private func modulationToggle(_ title: String, _ modulation: Composer2EventSpec.Modulation) -> some View {
        StageToggleRow(title: title, isOn: Binding(
            get: { events?.modulates.contains(modulation) ?? false },
            set: { on in
                HapticManager.shared.selection()
                document.editSelectedLayer {
                    if on { $0.events?.modulates.insert(modulation) } else { $0.events?.modulates.remove(modulation) }
                    if on, modulation == .color, $0.events?.color == nil { $0.events?.color = Composer2XY(x: 0.27, y: 0.28) }
                }
            }))
    }
}
