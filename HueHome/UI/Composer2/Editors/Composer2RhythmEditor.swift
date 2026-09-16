// Composer2RhythmEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Brightness over time, from a slow ambient breathe to a drum-hit burst.

import SwiftUI

struct Composer2RhythmEditorContent: View {
    let document: Composer2Document

    private var rhythm: Composer2Rhythm { document.selectedLayer.rhythm }
    private let periodRange: ClosedRange<Double> = 0.34...60

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Shape") {
                Composer2ChipRow(title: "Rhythm", options: [
                    ("Steady", Composer2Rhythm.Shape.steady, "minus"),
                    ("Breathe", .breathe, "lungs"),
                    ("Pulse", .pulse, "waveform.path"),
                    ("Heartbeat", .heartbeat, "heart"),
                    ("Flicker", .flicker, "flame"),
                    ("Swell", .swell, "water.waves.and.arrow.up"),
                    ("Burst", .burst, "burst")
                ], selection: document.layerBinding(\.rhythm.shape))
                if rhythm.shape != .steady && rhythm.shape != .flicker {
                    Composer2SliderRow(title: "Tempo", value: document.logSecondsBinding(\.rhythm.periodSeconds, range: periodRange),
                                       range: 0...1,
                                       format: { t in
                                           let s = document.logSeconds(t, range: periodRange)
                                           return s < 2 ? "\(Int((60 / s).rounded())) BPM" : composer2Seconds(s) + " per cycle"
                                       })
                }
                if rhythm.shape == .flicker {
                    Composer2SliderRow(title: "Flicker rate", value: document.layerBinding(\.rhythm.flickerRate), range: 0.1...2.5,
                                       format: { String(format: "%.1f per second", $0) })
                }
            }
            Composer2EditorSection(title: "Envelope") {
                Composer2SliderRow(title: "Attack", value: document.layerBinding(\.rhythm.attack), range: 0...1)
                Composer2SliderRow(title: "Decay", value: document.layerBinding(\.rhythm.decay), range: 0...1)
                Composer2SliderRow(title: "Depth", value: document.layerBinding(\.rhythm.depth), range: 0...1)
                if rhythm.shape == .pulse {
                    Composer2SliderRow(title: "Duty cycle", value: document.layerBinding(\.rhythm.duty), range: 0.05...0.95)
                }
                Composer2SliderRow(title: "Phase", value: document.layerBinding(\.rhythm.phase), range: 0...1)
            }
            Composer2EditorSection(title: "Brightness") {
                Composer2SliderRow(title: "Minimum", value: document.layerBinding(\.rhythm.minBrightness), range: 0...1)
                Composer2SliderRow(title: "Maximum", value: document.layerBinding(\.rhythm.maxBrightness), range: 0...1)
            }
            Composer2EditorSection(title: "Beat lock", subtitle: "When a beat clock is running, one cycle can follow the beat.") {
                Composer2ChipRow(title: "Cycle length", options: [
                    ("Free", 0.0, nil), ("1 beat", 1.0, nil), ("2 beats", 2.0, nil), ("4 beats", 4.0, nil), ("8 beats", 8.0, nil)
                ], selection: document.layerBinding(\.rhythm.quantizeBeats))
            }
        }
    }
}
