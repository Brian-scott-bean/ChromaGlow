// Composer2AudioEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Sound → light. The microphone is only asked for when a source is chosen
// and the composition is previewing or live.

import SwiftUI

struct Composer2AudioEditorContent: View {
    let document: Composer2Document

    private var audio: Composer2AudioModulation { document.selectedLayer.audio }

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Source", subtitle: "The microphone listens only while this composition previews or plays live. Nothing is recorded.") {
                Composer2ChipRow(title: "Listen to", options: [
                    ("Off", Composer2AudioModulation.Source.off, "speaker.slash"),
                    ("Amplitude", .amplitude, "waveform"),
                    ("Bass", .bass, "speaker.wave.1"),
                    ("Mid", .mid, "speaker.wave.2"),
                    ("Treble", .treble, "speaker.wave.3"),
                    ("Beat", .beat, "metronome"),
                    ("Hits", .onset, "bolt")
                ], selection: document.layerBinding(\.audio.source))
                if audio.isActive {
                    Composer2AudioPreview(audio: audio, accent: Composer2Theme.accent(for: .audio))
                }
            }
            if audio.isActive {
                Composer2EditorSection(title: "Response") {
                    Composer2SliderRow(title: "Sensitivity", value: document.layerBinding(\.audio.sensitivity), range: 0...1)
                    Composer2SliderRow(title: "Noise gate", value: document.layerBinding(\.audio.threshold), range: 0...0.9)
                    Composer2SliderRow(title: "Smoothing", value: document.layerBinding(\.audio.smoothing), range: 0...1)
                    Composer2SliderRow(title: "Intensity", value: document.layerBinding(\.audio.intensity), range: 0...1)
                    if audio.source == .beat || audio.source == .onset {
                        Composer2SliderRow(title: "Punch decay", value: document.layerBinding(\.audio.punchDecay), range: 0...1)
                    }
                }
                Composer2EditorSection(title: "What it changes") {
                    targetToggle("Brightness", .brightness)
                    if audio.targets.contains(.brightness) {
                        Composer2ChipRow(title: "Brightness responds by", options: [
                            ("Adding light", Composer2AudioModulation.BrightnessMode.punch, "plus.circle"),
                            ("Dimming when quiet", .dimWhenQuiet, "moon")
                        ], selection: document.layerBinding(\.audio.brightnessMode))
                    }
                    targetToggle("Color position", .palettePosition)
                    targetToggle("Motion speed", .motionSpeed)
                    targetToggle("Event chance", .eventProbability)
                    if audio.source == .onset {
                        StageToggleRow(title: "Trigger events on hits", isOn: document.layerBinding(\.audio.triggerEventsOnOnset))
                    }
                }
                if audio.source == .beat {
                    Composer2EditorSection(title: "Tempo") {
                        HStack(spacing: 12) {
                            Button {
                                HapticManager.shared.medium()
                                BeatClock.shared.tap()
                            } label: {
                                Label("Tap tempo", systemImage: "hand.tap")
                                    .font(HueFont.bodyMedium)
                                    .foregroundStyle(Composer2Theme.background)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                                    .background(Capsule().fill(Composer2Theme.coral))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Tap along to set the beat")
                            BeatStatusChip()
                            Spacer(minLength: 0)
                        }
                        Composer2ChipRow(title: "Color steps every", options: [
                            ("1 beat", 1.0, nil), ("2 beats", 2.0, nil), ("4 beats", 4.0, nil)
                        ], selection: document.layerBinding(\.audio.quantizeBeats))
                    }
                }
            }
        }
    }

    private func targetToggle(_ title: String, _ target: Composer2AudioModulation.Target) -> some View {
        StageToggleRow(title: title, isOn: Binding(
            get: { audio.targets.contains(target) },
            set: { on in
                HapticManager.shared.selection()
                document.editSelectedLayer {
                    if on { $0.audio.targets.insert(target) } else { $0.audio.targets.remove(target) }
                }
            }))
    }
}
