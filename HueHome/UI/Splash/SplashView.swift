// SplashView.swift
// ChromaGlow — Splash / Bridge Check (Luminous)
// Shown on cold start: the icon's spectrum ring glowing on the void. Checks
// Keychain, then calls onPaired or routes to BridgeSetupView.

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
    /// Routing (splash → paired/setup) happens exactly once. Guards the .task and the
    /// scenePhase safety net against double-firing.
    @State private var didRoute:        Bool    = false

    @Environment(\.scenePhase)  private var scenePhase

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

    /// The brand mark: the icon's neon spectrum ring, glowing on the void.
    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [LuminousPalette.violet.opacity(0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: 110))
                .frame(width: 220, height: 220)
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(LuminousPalette.spectrum, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 92, height: 92)
                .rotationEffect(.degrees(0))
                .shadow(color: LuminousPalette.magenta.opacity(0.8), radius: 14)
                .shadow(color: LuminousPalette.cyan.opacity(0.5), radius: 24)
            Capsule()
                .fill(LinearGradient(colors: [LuminousPalette.cyan, LuminousPalette.violet],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 40, height: 8)
                .offset(x: 26)
                .shadow(color: LuminousPalette.cyan.opacity(0.8), radius: 10)
        }
        .accessibilityHidden(true)
    }

    private var splashContent: some View {
        ZStack {
            LinearGradient(colors: [LuminousPalette.void, LuminousPalette.night, LuminousPalette.void],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                brandMark
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                Spacer().frame(height: 8)

                VStack(spacing: 6) {
                    Text("ChromaGlow")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [LuminousPalette.ink, LuminousPalette.ink.opacity(0.75)],
                                                        startPoint: .top, endPoint: .bottom))
                    Text("Light that feels alive")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .opacity(subtitleOpacity)
                }
                .opacity(titleOpacity)

                Spacer()

                // Progress line + Demo button
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(LuminousPalette.signalGradientHorizontal)
                                    .frame(width: geo.size.width * barProgress, height: 4)
                                    .shadow(color: LuminousPalette.cyan.opacity(0.6), radius: 6)
                            }
                        }
                        .frame(height: 4)

                        Text("Starting up…")
                            .font(.caption)
                            .foregroundStyle(LuminousPalette.inkTertiary)
                    }
                    .opacity(barOpacity)

                    // ── Explore Demo — fades in when bridge setup is shown ──
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { onDemo?() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                            Text("Explore Demo")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                        }
                        .foregroundStyle(LuminousPalette.cyan)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(Capsule().strokeBorder(LuminousPalette.cyan.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(showDemoButton ? 1 : 0)
                }
                .padding(.bottom, 60)
                .padding(.horizontal, 40)
            }
            .padding(.horizontal, 40)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: startIntroAnimation)
        // Route from a lifecycle-bound Task, not onAppear + DispatchQueue.asyncAfter.
        // On a fresh install the main thread is busy creating the SwiftData store and
        // the scene may not be .active when a one-shot timer fires, which used to leave
        // the splash stuck until a manual background/foreground. .task cancels + restarts
        // cleanly with the view, and the scenePhase net completes routing automatically
        // if the first attempt lands while the scene isn't rendering.
        .task { await routeAfterIntro() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await routeAfterIntro() } }
        }
    }

    // MARK: - Animation Sequence

    private func startIntroAnimation() {
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
    }

    /// Holds the splash for its cosmetic dwell, then routes to paired/setup exactly once.
    /// Idempotent (didRoute) so the .task and scenePhase net can both call it safely.
    /// The keychain check runs BEFORE the sleep so a fresh install (unpaired) reaches
    /// BridgeSetupView after ~0.7s instead of a fixed 2.1s — the icon spring (0.55s)
    /// and title fade (0.6s) have finished by then. Legacy-paired users keep the full
    /// dwell. Note this view only renders for unpaired/legacy users: AppRootView's
    /// onAppear routes modern paired users straight to MainTabView.
    private func routeAfterIntro() async {
        guard !didRoute else { return }

        let ip    = try? KeychainManager.shared.loadBridgeIP()
        let token = try? KeychainManager.shared.loadAPIToken()
        let alreadyPaired = (ip?.isEmpty == false) && (token?.isEmpty == false)

        try? await Task.sleep(for: .seconds(alreadyPaired ? 2.1 : 0.7))
        guard !didRoute else { return }

        didRoute = true
        StartupTimeline.mark("splash.route", alreadyPaired ? "legacy-paired → tabs" : "unpaired → setup")
        withAnimation(.easeInOut(duration: 0.4)) {
            if alreadyPaired {
                onPaired?()
            } else {
                showSetup = true
            }
        }
        if !alreadyPaired {
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeOut(duration: 0.4)) { showDemoButton = true }
        }
    }
}
