// SceneSpeedSheet.swift
// ChromaGlow — Scenes Browser
//
// Bottom sheet for setting dynamic scene speed. Shown from any scene card
// where isDynamic == true. Extracted verbatim from ScenesTabView.swift
// (Phase 0 of the Scenes overhaul) — no behavior change.

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

    private var speedLabel: String {
        let pct = Int(localSpeed * 100)
        switch pct {
        case 0..<20:  return "Very Slow"
        case 20..<40: return "Slow"
        case 40..<60: return "Medium"
        case 60..<80: return "Fast"
        default:      return "Very Fast"
        }
    }

    var body: some View {
        ZStack {
            StagePalette.stage.ignoresSafeArea()

            // Faint accent orb behind content
            Circle()
                .fill(RadialGradient(
                    colors: [scene.accentColor.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 180
                ))
                .frame(width: 360)
                .offset(y: -60)
                .blur(radius: 30)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 24)

                // Scene icon + name
                Image(systemName: scene.icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(scene.accentColor)
                    .symbolEffect(.pulse)

                Text(scene.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 10)

                Text("Dynamic Scene · \(speedLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 4)
                    .animation(.easeInOut(duration: 0.2), value: speedLabel)

                // ── Speed slider ──────────────────────────────
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.45))

                        Slider(value: $localSpeed, in: 0...1, step: 0.01)
                            .tint(scene.accentColor)
                            .onChange(of: localSpeed) { _, newVal in
                                onSpeedChange(newVal)
                            }

                        Image(systemName: "hare.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    Text("\(Int(localSpeed * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(scene.accentColor)
                        .animation(.none, value: localSpeed)
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)

                Spacer()

                // ── Activate button ───────────────────────────
                Button(action: onActivate) {
                    Label("Activate Scene", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(scene.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }
}
