// BridgeSetupView.swift
// CastChroma — Onboarding
//
// Premium step-driven onboarding flow.
// Phases: idle → scanning → bridgeFound → pairing → paired → error
// Developer console is hidden behind a DEBUG-only toggle.

import SwiftUI
import SwiftData

// MARK: - BridgeSetupView

/// Thin shim that constructs the discovery VM exactly ONCE per setup-screen
/// lifetime. As a `@State` initial value inside the content view it was
/// re-evaluated on every parent body re-render — a full @Observable VM +
/// BridgeDiscoveryService + Combine pipelines built and discarded on the main
/// thread each time (measured: repeated `discovery.vm-init.done` marks inside
/// the fresh-install hang window on device).
struct BridgeSetupView: View {

    var onPaired:        (() -> Void)? = nil
    var onDemo:          (() -> Void)? = nil
    var isAddingAdditional: Bool       = false
    var onBridgeAdded:   ((BridgeRecord) -> Void)? = nil

    @State private var vm: BridgeDiscoveryViewModel? = nil

    var body: some View {
        Group {
            if let vm {
                BridgeSetupContent(
                    onPaired: onPaired,
                    onDemo: onDemo,
                    isAddingAdditional: isAddingAdditional,
                    onBridgeAdded: onBridgeAdded,
                    vm: vm
                )
            } else {
                // Static "getting ready" frame — painted BEFORE the heavy
                // BridgeSetupContent tree is constructed (device stacks showed
                // multi-second Swift conformance scans during that build).
                // Deliberately zero animation/blur: while the main thread is
                // busy nothing can animate, but a friendly still frame beats a
                // frozen splash.
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.05, blue: 0.12),
                            Color(red: 0.08, green: 0.06, blue: 0.16),
                            Color(red: 0.05, green: 0.05, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                    .ignoresSafeArea()
                    Text("Getting things ready…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        // .task (not .onAppear): async, so the placeholder commits a frame
        // first, THEN the expensive content construction happens behind it.
        .task { if vm == nil { vm = BridgeDiscoveryViewModel() } }
    }
}

struct BridgeSetupContent: View {

    var onPaired:        (() -> Void)? = nil
    var onDemo:          (() -> Void)? = nil
    var isAddingAdditional: Bool       = false
    var onBridgeAdded:   ((BridgeRecord) -> Void)? = nil

    /// Owned by the BridgeSetupView shim — constructed once, injected here.
    let vm: BridgeDiscoveryViewModel
    @State private var showManualEntry = false
    @State private var showDebugLog    = false
    @State private var manualIP        = ""
    // ── Share Invite (home-join + guest invite) ───────────
    @State private var showInviteScanner = false
    @State private var presentedInvite: JoinInvitePresentation?
    @State private var presentedGuestInvite: GuestInvitePresentation?
    @State private var inviteError: InvitePayloadError?

    private struct JoinInvitePresentation: Identifiable {
        let id = UUID()
        let payload: HomeJoinPayload
    }

    private struct GuestInvitePresentation: Identifiable {
        let id = UUID()
        let payload: GuestInvitePayload
    }
    /// The record created (or reused) for the CURRENT pairing — finalized the
    /// moment the phase reaches `.paired` (L-15: record + credentials are
    /// committed together, not deferred to a button tap the user may skip).
    @State private var pairedRecord: BridgeRecord?
    @Environment(\.modelContext) private var modelContext

    // Pulse animation for bridge icon
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // ── Background gradient ──────────────────────────────
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.12),
                    Color(red: 0.08, green: 0.06, blue: 0.16),
                    Color(red: 0.05, green: 0.05, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            .ignoresSafeArea()

            // Subtle ambient glow behind icon. RadialGradient, NOT .blur():
            // the 60pt gaussian on a 320pt layer was a multi-second CPU
            // rasterization on device (CGDisplayListDrawInContextDelegate in
            // the build-12 hang stacks), re-paid on every accent change.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(0.08), accentColor.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 160
                    )
                )
                .frame(width: 320, height: 320)
                .offset(y: -80)

            VStack(spacing: 0) {
                // ── Top: logo / step icon ────────────────────────
                Spacer()
                bridgeIcon
                    .padding(.bottom, 32)

                // ── Phase content card ───────────────────────────
                phaseContent
                    .padding(.horizontal, 28)

                Spacer()
                Spacer()

                // ── Debug log (DEBUG builds only) ────────────────
                #if DEBUG
                debugToggle
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                #endif
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showManualEntry) { manualIPSheet }
        // Drain on dismiss, not inside onFound — presenting the join sheet
        // while the scanner is still dismissing drops it (Studio's pattern).
        .sheet(isPresented: $showInviteScanner, onDismiss: drainPendingInvite) {
            ScanSceneView(title: "SCAN AN INVITE",
                          hint: "Point at a ChromaGlow invite QR code") { url in
                // Accepts BOTH invite kinds (home-join and the Phase 2
                // token invite); a scene QR refuses honestly.
                DeepLinkCoordinator.shared.acceptEitherInviteLink(url)
            }
        }
        .sheet(item: $presentedInvite) { presentation in
            JoinSharedHomeView(
                payload: presentation.payload,
                isAddingAdditional: isAddingAdditional,
                onBridgeAdded: onBridgeAdded,
                onFirstPairingComplete: onPaired
            )
        }
        .sheet(item: $presentedGuestInvite) { presentation in
            GuestInviteAcceptView(
                payload: presentation.payload,
                isAddingAdditional: isAddingAdditional,
                onBridgeAdded: onBridgeAdded,
                onFirstPairingComplete: onPaired
            )
        }
        .alert("Can't Open Invite", isPresented: Binding(
            get: { inviteError != nil },
            set: { if !$0 { inviteError = nil } }
        )) {
            Button("OK", role: .cancel) { inviteError = nil }
        } message: {
            Text(inviteError?.localizedDescription ?? "")
        }
        // An invite LINK tapped while unpaired lands before MainTabView
        // exists — this screen is what's on stage, so it drains too.
        .task { drainPendingInvite() }
        .onChange(of: DeepLinkCoordinator.shared.openToken) { _, _ in drainPendingInvite() }
        .onAppear {
            StartupTimeline.mark("setup.appear")
            pulsing = true
        }
        .onChange(of: vm.phase) { _, newPhase in
            switch newPhase {
            case .paired(let ip, _):
                finalizePairedRecord(host: ip)
            case .idle, .scanning:
                // Re-scanning (e.g. "Pair another bridge") starts a fresh
                // pairing — the previous record is already persisted.
                pairedRecord = nil
            default:
                break
            }
        }
    }

    // MARK: - Accent per phase

    private var accentColor: Color {
        switch vm.phase {
        case .idle:          return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .scanning:      return .cyan
        case .bridgeFound:   return .green
        case .pairing:       return .orange
        case .paired:        return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .error:         return .red
        }
    }

    // MARK: - Bridge Icon

    private var bridgeIcon: some View {
        ZStack {
            // Outer pulse ring
            Circle()
                .strokeBorder(accentColor.opacity(pulsing ? 0.0 : 0.35), lineWidth: 1.5)
                .frame(width: 110, height: 110)
                .scaleEffect(pulsing ? 1.45 : 1.0)
                .animation(
                    isPulsing ? .easeOut(duration: 1.6).repeatForever(autoreverses: false) : .default,
                    value: pulsing
                )

            // Inner glow disc
            Circle()
                .fill(accentColor.opacity(0.12))
                .frame(width: 88, height: 88)

            // Icon
            Image(systemName: phaseIcon)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .symbolEffect(.bounce, value: vm.phase == .idle ? 0 : 1)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: phaseIcon)
    }

    private var isPulsing: Bool {
        switch vm.phase {
        case .scanning, .pairing: return true
        default: return false
        }
    }

    private var phaseIcon: String {
        switch vm.phase {
        case .idle:           return "network"
        case .scanning:       return "antenna.radiowaves.left.and.right"
        case .bridgeFound:    return "checkmark.circle"
        case .pairing:        return "link.circle"
        case .paired:         return "checkmark.seal.fill"
        case .error:          return "exclamationmark.triangle"
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch vm.phase {
        case .idle:
            idleContent
        case .scanning:
            scanningContent
        case .bridgeFound(let bridge):
            bridgeFoundContent(bridge: bridge)
        case .pairing(let bridge):
            pairingContent(bridge: bridge)
        case .paired(let ip, let token):
            pairedContent(ip: ip, token: token)
        case .error(let msg):
            errorContent(message: msg)
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Connect Your Bridge")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Make sure your iPhone and Hue Bridge are on the same Wi-Fi network.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Primary CTA
                primaryButton("Scan for Bridge", icon: "magnifyingglass") {
                    vm.startScan()
                }

                // Manual fallback
                secondaryButton("Enter IP Manually", icon: "keyboard") {
                    showManualEntry = true
                }

                // Someone else's bridge — scan their home-join invite QR.
                secondaryButton("Join a Shared Home", icon: "qrcode.viewfinder") {
                    showInviteScanner = true
                }

                // Demo
                if onDemo != nil {
                    demoButton
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Scanning

    private var scanningContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Searching…")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text(vm.scanningLabel)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.4), value: vm.scanningLabel)
            }

            // Discovery method step indicators
            VStack(spacing: 8) {
                discoveryStepRow(
                    icon: "wifi",
                    label: "Wi-Fi scan (mDNS)",
                    active: vm.scanningLabel.contains("Wi")
                )
                discoveryStepRow(
                    icon: "cloud",
                    label: "Philips cloud discovery",
                    active: vm.scanningLabel.contains("cloud")
                )
                discoveryStepRow(
                    icon: "keyboard",
                    label: "Manual IP entry",
                    active: false,
                    muted: true
                )
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))

            if !vm.discoveredBridgeChoices.isEmpty {
                discoveredBridgeChooser
            }

            secondaryButton("Enter IP Manually", icon: "keyboard") {
                vm.resetToIdle()
                showManualEntry = true
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var discoveredBridgeChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.discoveredBridgeChoices.count == 1 ? "Bridge found — select to continue" : "Bridges found — select yours")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))

            ForEach(vm.discoveredBridgeChoices) { bridge in
                Button {
                    vm.selectDiscoveredBridge(bridge)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.router")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bridge.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(bridge.host):\(bridge.port)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accentColor.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func discoveryStepRow(icon: String, label: String, active: Bool, muted: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? accentColor.opacity(0.2) : .white.opacity(0.05))
                    .frame(width: 32, height: 32)
                if active {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(accentColor)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(muted ? .white.opacity(0.25) : .white.opacity(0.45))
                }
            }
            Text(label)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : (muted ? .white.opacity(0.25) : .white.opacity(0.50)))
            Spacer()
            if active {
                Text("Active")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(accentColor.opacity(0.15)))
            }
        }
    }

    // MARK: - Bridge Found

    private func bridgeFoundContent(bridge: BridgeEndpoint) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Bridge Found!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                // Bridge info pill
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text("\(bridge.name)  ·  \(bridge.host)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.08)))
            }

            // Link-button instruction card
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(.orange.opacity(0.18)).frame(width: 40, height: 40)
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Press the bridge button")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Push the round button on top of your Hue Bridge, then tap Pair below. You have about 30 seconds.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.2), lineWidth: 1))

            VStack(spacing: 12) {
                primaryButton("Pair with Bridge", icon: "link") {
                    vm.pairWithBridge(bridge)
                }
                secondaryButton("Scan Again", icon: "arrow.clockwise") {
                    vm.resetToIdle()
                    vm.startScan()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Pairing

    private func pairingContent(bridge: BridgeEndpoint) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Text("Connecting…")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("Pairing with \(bridge.name). Don't close the app.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Paired ✅

    private func pairedContent(ip: String, token: String) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("ChromaGlow is paired with your bridge and ready to go.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            // Bridge summary pill
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
                Text(ip)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.green.opacity(0.10)))

            VStack(spacing: 12) {
                primaryButton(
                    isAddingAdditional ? "Add to ChromaGlow" : "Continue to App",
                    icon: isAddingAdditional ? "plus.circle.fill" : "lightbulb.fill"
                ) {
                    handlePairedAction(ip: ip, token: token)
                }
                // Round-2 Item 2: multi-bridge homes can pair everything in one
                // onboarding pass. The just-paired record is already persisted
                // (committed at .paired), so returning to scanning loses nothing.
                if !isAddingAdditional {
                    secondaryButton("Pair Another Bridge", icon: "plus.circle") {
                        vm.resetToIdle()
                        vm.startScan()
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Something went wrong")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                primaryButton("Try Again", icon: "arrow.clockwise") {
                    vm.resetToIdle()
                }
                secondaryButton("Enter IP Manually", icon: "keyboard") {
                    vm.resetToIdle()
                    showManualEntry = true
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Reusable Button Styles

    private func primaryButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.05, green: 0.05, blue: 0.12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentColor)
                    .shadow(color: accentColor.opacity(0.4), radius: 18, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.60))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var demoButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { onDemo?() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text("Explore Demo")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(accentColor.opacity(0.75))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Manual IP Sheet

    private var manualIPSheet: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.13).ignoresSafeArea()
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Enter Bridge IP")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Find your bridge IP in the Philips Hue app under Settings → My Hue System → Hue Bridges.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }

                    TextField("192.168.1.100", text: $manualIP)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1))

                    Button {
                        let ip = manualIP.trimmingCharacters(in: .whitespaces)
                        guard !ip.isEmpty else { return }
                        let bridge = BridgeEndpoint(name: "Hue Bridge", host: ip, port: 443)
                        showManualEntry = false
                        vm.phase = .bridgeFound(bridge)
                    } label: {
                        Text("Connect")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(red: 0.05, green: 0.05, blue: 0.12))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(RoundedRectangle(cornerRadius: 14).fill(accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)

                    Spacer()
                }
                .padding(28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Debug Log (DEBUG only)

    #if DEBUG
    private var debugToggle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDebugLog.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                    Text("Debug log (\(vm.logLines.count) events)")
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Image(systemName: showDebugLog ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.25))
            }
            .buttonStyle(.plain)

            if showDebugLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(8)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
            }
        }
    }
    #endif

    // MARK: - Paired Record (L-15/L-17)

    /// Commit the BridgeRecord as soon as pairing succeeds. Credentials are
    /// already in the per-bridge Keychain slots (written by the view model
    /// before `.paired`); this pairs them with exactly one record — deduped
    /// by canonical bridgeid — and SURFACES failures instead of discarding
    /// them (the old `_ = migrateLegacyCredentials(...)` pattern).
    private func finalizePairedRecord(host: String) {
        guard pairedRecord == nil else { return }
        guard let mintedID = vm.pairedRecordID else {
            // Test seams may bypass the credential write; nothing to register.
            return
        }
        // "My Bridge" only for the very first record — a second onboarding
        // pairing ("Pair Another Bridge") gets a distinct name like the
        // add-additional flow.
        let isFirstRecord = ((try? modelContext.fetchCount(FetchDescriptor<BridgeRecord>())) ?? 0) == 0
        let name = isFirstRecord ? "My Bridge" : "Bridge \(mintedID.prefix(4).uppercased())"
        do {
            let registration = try BridgePairingRegistrar.register(
                mintedID: mintedID,
                host: host,
                canonicalBridgeID: vm.pairedCanonicalBridgeID,
                preferredName: name,
                sortOrder: isFirstRecord ? 0 : 999,
                modelContext: modelContext
            )
            pairedRecord = registration.record
        } catch {
            vm.phase = .error("Pairing succeeded but the bridge could not be saved — please try pairing again.\n(\(error.localizedDescription))")
        }
    }

    // MARK: - Share Invite drain

    private func drainPendingInvite() {
        let coordinator = DeepLinkCoordinator.shared
        if let payload = coordinator.pendingInvite {
            coordinator.clearInvite()
            presentedInvite = JoinInvitePresentation(payload: payload)
        } else if let payload = coordinator.pendingGuestInvite {
            coordinator.clearInvite()
            presentedGuestInvite = GuestInvitePresentation(payload: payload)
        } else if let error = coordinator.pendingInviteError {
            coordinator.clearInvite()
            inviteError = error
        }
    }

    // MARK: - Paired Action

    private func handlePairedAction(ip: String, token: String) {
        // Record + credentials were committed when the phase hit .paired —
        // this button only routes onward.
        if isAddingAdditional {
            if let record = pairedRecord {
                onBridgeAdded?(record)
            }
        } else {
            onPaired?()
        }
    }
}
