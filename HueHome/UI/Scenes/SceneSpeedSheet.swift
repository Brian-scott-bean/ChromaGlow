// SceneSpeedSheet.swift
// ChromaGlow — Scenes (Luminous)
//
// How fast a dynamic scene's colours move. The sheet glows in the scene's
// colours, shows its palette as orbs, and offers one glow slider and one
// button. The slider writes the speed as it moves (the host stores it for
// the next recall); Activate recalls the scene at that speed.

import SwiftUI

struct SceneSpeedSheet: View {

    let scene:         GlobalSceneItem
    let onSpeedChange: (Double) -> Void
    let onActivate:    () -> Void

    @State private var localSpeed: Double

    init(scene: GlobalSceneItem,
         onSpeedChange: @escaping (Double) -> Void,
         onActivate: @escaping () -> Void) {
        self.scene         = scene
        self.onSpeedChange = onSpeedChange
        self.onActivate    = onActivate
        _localSpeed        = State(initialValue: scene.speed)
    }

    private var colors: [Color] { LuminousScenePalette.colors(for: scene) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LuminousSceneArt(colors: colors, isActive: true, lamps: 7, height: 84)
                .padding(.top, 8)

            LuminousScreenTitle(title: scene.name,
                                eyebrow: "Dynamic scene",
                                eyebrowSymbol: "bolt.fill",
                                eyebrowTint: LuminousScenePalette.accent(for: scene),
                                subtitle: "Its colors drift on their own. Choose how quickly.")

            VStack(alignment: .leading, spacing: 6) {
                LuminousGlowSlider(title: "Speed",
                                   symbol: "speedometer",
                                   value: $localSpeed,
                                   range: 0...1,
                                   colors: colors,
                                   format: { "\(Int(($0 * 100).rounded()))% · \(Self.label(for: $0))" })
                HStack {
                    Label("Slower", systemImage: "tortoise.fill")
                    Spacer()
                    Label("Faster", systemImage: "hare.fill")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(LuminousPalette.inkSecondary)
                .labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            }
            .padding(16)
            .luminousGlass()

            Spacer(minLength: 0)

            LuminousPrimaryButton(title: "Activate Scene", symbol: "play.fill", action: onActivate)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, HueSpacing.screenH)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { LuminousAmbience(colors: colors) }
        .onChange(of: localSpeed) { _, newVal in
            onSpeedChange(newVal)
        }
        .presentationDetents([.medium, .large])
        .luminousSheet()
    }

    private static func label(for speed: Double) -> String {
        switch Int(speed * 100) {
        case 0..<20:  return "Very Slow"
        case 20..<40: return "Slow"
        case 40..<60: return "Medium"
        case 60..<80: return "Fast"
        default:      return "Very Fast"
        }
    }
}
