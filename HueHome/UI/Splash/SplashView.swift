// SplashView.swift
// HueHome Pro — Stage 1
// Shown on cold start. Checks Keychain, then calls onPaired or routes to BridgeSetupView.

import SwiftUI

struct SplashView: View {
    var onPaired: (() -> Void)? = nil
    var onDemo:   (() -> Void)? = nil   // called when user picks "Explore Demo"

    @State private var iconScale:       CGFloat = 0.4
    @State private var iconOpacity:     Double  = 0.0
    @State private var titleOpacity:    Double  = 0.0
    @State private var subtitleOpacity: Double  = 0.0
    @State private var barProgress:     CGFloat = 0.0
    @State private var barOpacity:      Double  = 0.0
    @State private var showSetup:       Bool    = false
    @State private var showDemoButton:  Bool    = false

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if showSetup {
            BridgeSetupView(
                onPaired: onPaired,
                onDemo:   onDemo
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom)),
                removal: .opacity
            ))
        } else {
            splashContent
        }
    }

    // MARK: - Splash Layout

    private var splashContent: some View {
        ZStack {
            (colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Icon
                ZStack {
                    AmberRadialGlow(radius: 70)
                    Circle()
                        .fill(HuePalette.amber.opacity(0.15))
                        .frame(width: 90, height: 90)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(LinearGradient.hueAmberVertical)
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)

                Spacer().frame(height: 28)

                // Title
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("ChromaForge")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(colorScheme == .dark
                                             ? HuePalette.Noir.textPrimary
                                             : HuePalette.Estate.textPrimary)
                        Text("Pro")
                            .font(.system(size: 34, weight: .thin, design: .rounded))
                            .foregroundStyle(HuePalette.amber)
                    }
                    Text("Your lighting ecosystem")
                        .font(HueFont.caption)
                        .foregroundStyle(colorScheme == .dark
                                         ? HuePalette.Noir.textTertiary
                                         : HuePalette.Estate.textTertiary)
                }
                .opacity(titleOpacity)

                Spacer()

                // Progress bar + Demo button
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(colorScheme == .dark
                                          ? HuePalette.Noir.sliderTrack
                                          : HuePalette.Estate.sliderTrack)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(LinearGradient.hueAmberFill)
                                    .frame(width: geo.size.width * barProgress, height: 4)
                            }
                        }
                        .frame(height: 4)

                        Text("Starting up…")
                            .font(HueFont.micro)
                            .foregroundStyle(colorScheme == .dark
                                             ? HuePalette.Noir.textTertiary
                                             : HuePalette.Estate.textTertiary)
                    }
                    .opacity(barOpacity)

                    // ── Explore Demo — fades in when bridge setup is shown ──
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { onDemo?() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .medium))
                            Text("Explore Demo")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(HuePalette.amber.opacity(0.75))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background {
                            Capsule()
                                .strokeBorder(HuePalette.amber.opacity(0.25), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(showDemoButton ? 1 : 0)
                }
                .padding(.bottom, 60)
                .padding(.horizontal, 40)
            }
            .padding(.horizontal, 40)
        }
        .onAppear(perform: runAnimation)
    }

    // MARK: - Animation Sequence

    private func runAnimation() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
            iconScale   = 1.0
            iconOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.25)) { titleOpacity = 1.0 }
        withAnimation(.easeOut(duration: 0.3).delay(0.5))   {
            subtitleOpacity = 1.0
            barOpacity      = 1.0
        }
        withAnimation(.easeInOut(duration: 1.4).delay(0.6)) { barProgress = 1.0 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            let ip    = try? KeychainManager.shared.loadBridgeIP()
            let token = try? KeychainManager.shared.loadAPIToken()
            let alreadyPaired = (ip?.isEmpty == false) && (token?.isEmpty == false)

            withAnimation(.easeInOut(duration: 0.4)) {
                if alreadyPaired {
                    onPaired?()
                } else {
                    showSetup = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.4)) { showDemoButton = true }
                    }
                }
            }
        }
    }
}
