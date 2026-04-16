// SplashView.swift
// HueHome Pro — Splash Screen
//
// Shown during app cold-start. Provides visual feedback during Swift runtime
// initialization. Transitions to BridgeSetupView once the animation completes.
//
// Intentionally kept render-lightweight — no heavy GeometryReader or async work
// during this window.

import SwiftUI

struct SplashView: View {

    @State private var iconScale: CGFloat       = 0.4
    @State private var iconOpacity: Double      = 0.0
    @State private var titleOpacity: Double     = 0.0
    @State private var subtitleOpacity: Double  = 0.0
    @State private var barProgress: CGFloat     = 0.0
    @State private var barOpacity: Double       = 0.0
    @State private var showMain: Bool           = false
    @State private var alreadyPaired: Bool      = false  // set during animation, drives destination

    var body: some View {
        if showMain {
            if alreadyPaired {
                NavigationStack {
                    DashboardView()
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal:   .opacity
                ))
            } else {
                BridgeSetupView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal:   .opacity
                    ))
            }
        } else {
            splashContent
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Splash Layout
    // ──────────────────────────────────────────────

    private var splashContent: some View {
        ZStack {
            // Background
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Icon ─────────────────────────────────
                ZStack {
                    // Pulsing glow ring
                    Circle()
                        .fill(Color.yellow.opacity(0.18))
                        .frame(width: 110, height: 110)
                        .scaleEffect(iconScale * 1.3)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(0.4),
                            value: iconScale
                        )

                    // Icon circle
                    Circle()
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 90, height: 90)

                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)

                Spacer().frame(height: 28)

                // ── Title ────────────────────────────────
                Text("HueHome")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .opacity(titleOpacity)

                Text("Pro")
                    .font(.system(size: 34, weight: .thin, design: .rounded))
                    .foregroundStyle(.secondary)
                    .opacity(titleOpacity)

                Spacer().frame(height: 8)

                Text("Connecting to your light ecosystem")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(subtitleOpacity)

                Spacer()

                // ── Progress Bar ─────────────────────────
                VStack(spacing: 10) {
                    loadingBar
                    Text("Starting up…")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                .opacity(barOpacity)
                .padding(.bottom, 60)
            }
            .padding(.horizontal, 40)
        }
        .onAppear(perform: runAnimation)
    }

    // ── Loading Bar ───────────────────────────────
    private var loadingBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 4)

                // Fill
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * barProgress, height: 4)
            }
        }
        .frame(height: 4)
    }

    // ──────────────────────────────────────────────
    // MARK: - Animation Sequence
    // ──────────────────────────────────────────────

    private func runAnimation() {
        // Step 1 — icon bounces in (0.0s)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
            iconScale   = 1.0
            iconOpacity = 1.0
        }

        // Step 2 — title fades up (0.25s)
        withAnimation(.easeOut(duration: 0.35).delay(0.25)) {
            titleOpacity = 1.0
        }

        // Step 3 — subtitle + bar appear (0.5s)
        withAnimation(.easeOut(duration: 0.3).delay(0.5)) {
            subtitleOpacity = 1.0
            barOpacity      = 1.0
        }

        // Step 4 — progress bar fills over 1.4s (0.6s → 2.0s)
        withAnimation(.easeInOut(duration: 1.4).delay(0.6)) {
            barProgress = 1.0
        }

        // Step 5 — check Keychain for existing credentials, then transition (2.1s)
        // Keychain reads are synchronous and fast — safe to call on main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            let ip    = try? KeychainManager.shared.loadBridgeIP()
            let token = try? KeychainManager.shared.loadAPIToken()
            alreadyPaired = (ip?.isEmpty == false) && (token?.isEmpty == false)

            withAnimation(.easeInOut(duration: 0.4)) {
                showMain = true
            }
        }
    }
}
