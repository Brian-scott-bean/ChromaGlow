// BridgeSetupView.swift
// ChromaGlow — Onboarding (Luminous)
//
// Step-driven pairing in the app's own language: a small dark stage of
// lamps that comes alive as you go — dark while you start, one lamp glows
// when the bridge is found, the whole room lights in the spectrum when
// you're paired. Phases: idle → scanning → bridgeFound → pairing → paired →
// error. Developer console is hidden behind a DEBUG-only toggle.

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
                    LinearGradient(colors: [LuminousPalette.void, LuminousPalette.night, LuminousPalette.void],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                    Text("Getting things ready…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LuminousPalette.inkSecondary)
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
    @State private var manualIPError: String?
    @FocusState private var manualIPFocused: Bool
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
    /// Injected app-wide at the WindowGroup root (sheets inherit it).
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    var body: some View {
        ZStack {
            // The room the lamps will light — tinted by where pairing is.
            // (Radial gradients on one Canvas; never a large .blur(), which
            // was a multi-second CPU rasterisation on device.)
            LuminousAmbience(colors: ambienceColors, intensity: 0.8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    LuminousStateChip(text: phaseChip, dot: accentColor, glowing: isPulsing)
                        .padding(.top, 8)
                    setupStage
                    phaseContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // ── Debug log (DEBUG builds only) ────────────────
                    #if DEBUG
                    debugToggle
                        .padding(.top, 8)
                    #endif
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
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
        case .idle:          return LuminousPalette.cyan
        case .scanning:      return LuminousPalette.cyan
        case .bridgeFound:   return LuminousPalette.live
        case .pairing:       return LuminousPalette.amber
        case .paired:        return LuminousPalette.live
        case .error:         return LuminousPalette.amber
        }
    }

    private var ambienceColors: [Color] {
        switch vm.phase {
        case .paired:   return Self.spectrum
        case .error:    return [LuminousPalette.amber.opacity(0.6)]
        default:        return [accentColor, LuminousPalette.violet]
        }
    }

    private var phaseChip: String {
        switch vm.phase {
        case .idle:        return isAddingAdditional ? "Add a bridge" : "Welcome to ChromaGlow"
        case .scanning:    return "Looking for your bridge"
        case .bridgeFound: return "Bridge found"
        case .pairing:     return "Pairing"
        case .paired:      return "Paired"
        case .error:       return "Needs attention"
        }
    }

    private var isPulsing: Bool {
        switch vm.phase {
        case .scanning, .pairing: return true
        default: return false
        }
    }

    // MARK: - The stage that comes alive

    /// The lamps of a room-to-be, in the icon's spectrum.
    private static let spectrum: [Color] = [Color(hex: "#FFD24A"), Color(hex: "#FF7A3D"), Color(hex: "#FF3D8B"),
                                            Color(hex: "#9B5CFF"), Color(hex: "#3D8BFF"), Color(hex: "#3DFFB0")]

    /// How many lamps are lit at each step: dark → one → the room.
    private var litLamps: Int {
        switch vm.phase {
        case .idle, .error:  return 0
        case .scanning:      return 1
        case .bridgeFound:   return 2
        case .pairing:       return 4
        case .paired:        return Self.spectrum.count
        }
    }

    private var setupStage: some View {
        let lamps = Self.spectrum.enumerated().map { i, color in
            (color: color, level: i < litLamps ? 0.9 : 0.0)
        }
        return ZStack(alignment: .bottomLeading) {
            Canvas(rendersAsynchronously: false) { ctx, size in
                LuminousMiniRoomStage.draw(in: &ctx, size: size, lamps: lamps)
            }
            .frame(height: 150)
            Image(systemName: phaseIcon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .symbolEffect(.pulse, isActive: isPulsing)
                .padding(12)
        }
        .luminousStageFrame(isLive: isPaired)
        .animation(.easeInOut(duration: 0.6), value: litLamps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(litLamps) of \(Self.spectrum.count) lamps lit")
    }

    private var isPaired: Bool {
        if case .paired = vm.phase { return true }
        return false
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
        VStack(alignment: .leading, spacing: 22) {
            LuminousScreenTitle(title: isAddingAdditional ? "Add a bridge" : "Let's light up your home",
                                eyebrow: "Connect your bridge",
                                eyebrowSymbol: "wifi.router",
                                eyebrowTint: LuminousPalette.cyan,
                                subtitle: "Make sure your iPhone and Hue Bridge are on the same Wi-Fi network.")

            VStack(spacing: 12) {
                LuminousPrimaryButton(title: "Scan for Bridge", symbol: "magnifyingglass") {
                    vm.startScan()
                }
                LuminousSecondaryButton(title: "Enter IP Manually", symbol: "keyboard") {
                    showManualEntry = true
                }
                // Someone else's bridge — scan their home-join invite QR.
                LuminousSecondaryButton(title: "Join a Shared Home", symbol: "qrcode.viewfinder") {
                    showInviteScanner = true
                }
                if onDemo != nil {
                    demoButton
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Scanning

    private var scanningContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            LuminousScreenTitle(title: "Searching…",
                                eyebrow: "Looking on your network",
                                eyebrowSymbol: "antenna.radiowaves.left.and.right",
                                eyebrowTint: LuminousPalette.cyan,
                                subtitle: vm.scanningLabel)
                .animation(.easeInOut(duration: 0.4), value: vm.scanningLabel)

            // Discovery method steps
            LuminousGroup {
                discoveryStepRow(icon: "wifi", label: "Scanning your Wi-Fi",
                                 active: vm.scanningLabel.contains("Wi"))
                LuminousRowDivider()
                discoveryStepRow(icon: "cloud", label: "Philips cloud discovery",
                                 active: vm.scanningLabel.contains("cloud"))
                LuminousRowDivider()
                discoveryStepRow(icon: "keyboard", label: "Manual IP entry", active: false, muted: true)
            }

            if !vm.discoveredBridgeChoices.isEmpty {
                discoveredBridgeChooser
            }

            LuminousSecondaryButton(title: "Enter IP Manually", symbol: "keyboard") {
                vm.resetToIdle()
                showManualEntry = true
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var discoveredBridgeChooser: some View {
        LuminousGroup(title: vm.discoveredBridgeChoices.count == 1 ? "Bridge found — select to continue" : "Bridges found — select yours") {
            ForEach(Array(vm.discoveredBridgeChoices.enumerated()), id: \.element.id) { index, bridge in
                Button {
                    vm.selectDiscoveredBridge(bridge)
                } label: {
                    LuminousRow(symbol: "wifi.router", tint: LuminousPalette.live,
                                title: bridge.name, subtitle: "\(bridge.host):\(bridge.port)")
                }
                .buttonStyle(.plain)
                if index < vm.discoveredBridgeChoices.count - 1 { LuminousRowDivider() }
            }
        }
    }

    private func discoveryStepRow(icon: String, label: String, active: Bool, muted: Bool = false) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if active {
                    Circle().fill(accentColor.opacity(0.2)).frame(width: 36, height: 36)
                    ProgressView().scaleEffect(0.7).tint(accentColor)
                } else {
                    LuminousIconBadge(symbol: icon, tint: LuminousPalette.inkSecondary, size: 36, lit: !muted)
                }
            }
            .frame(width: 36, height: 36)
            Text(label)
                .font(.body.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? LuminousPalette.ink : (muted ? LuminousPalette.inkTertiary : LuminousPalette.inkSecondary))
            Spacer(minLength: 0)
            if active {
                Text("Active")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(Capsule().fill(accentColor.opacity(0.15)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bridge Found

    private func bridgeFoundContent(bridge: BridgeEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            LuminousScreenTitle(title: "Bridge found",
                                eyebrow: "\(bridge.name) · \(bridge.host)",
                                eyebrowSymbol: "wifi",
                                eyebrowTint: LuminousPalette.live,
                                subtitle: "One last step and your lights are yours.")

            // Link-button instruction
            HStack(alignment: .top, spacing: 14) {
                LuminousIconBadge(symbol: "hand.tap.fill", tint: LuminousPalette.amber, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Press the bridge button")
                        .font(LuminousType.cardTitleSmall)
                        .foregroundStyle(LuminousPalette.ink)
                    Text("Push the round button on top of your Hue Bridge, then tap Pair below. You have about 30 seconds.")
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .luminousGlass(accent: LuminousPalette.amber, selected: true)

            VStack(spacing: 12) {
                LuminousPrimaryButton(title: "Pair with Bridge", symbol: "link") {
                    vm.pairWithBridge(bridge)
                }
                LuminousSecondaryButton(title: "Scan Again", symbol: "arrow.clockwise") {
                    vm.resetToIdle()
                    vm.startScan()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Pairing

    private func pairingContent(bridge: BridgeEndpoint) -> some View {
        LuminousScreenTitle(title: "Connecting…",
                            eyebrow: bridge.name,
                            eyebrowSymbol: "link",
                            eyebrowTint: LuminousPalette.amber,
                            subtitle: "Pairing with \(bridge.name). Don't close the app.")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Paired

    private func pairedContent(ip: String, token: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            LuminousScreenTitle(title: "You're all set",
                                eyebrow: "Paired · \(ip)",
                                eyebrowSymbol: "checkmark.seal.fill",
                                eyebrowTint: LuminousPalette.live,
                                subtitle: "ChromaGlow is paired with your bridge and ready to go.")

            VStack(spacing: 12) {
                LuminousPrimaryButton(title: isAddingAdditional ? "Add to ChromaGlow" : "Continue to App",
                                      symbol: isAddingAdditional ? "plus.circle.fill" : "lightbulb.fill") {
                    handlePairedAction(ip: ip, token: token)
                }
                // Multi-bridge homes can pair everything in one onboarding
                // pass. The just-paired record is already persisted
                // (committed at .paired), so returning to scanning loses nothing.
                if !isAddingAdditional {
                    LuminousSecondaryButton(title: "Pair Another Bridge", symbol: "plus.circle") {
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
        VStack(alignment: .leading, spacing: 22) {
            LuminousScreenTitle(title: "Something went wrong",
                                eyebrow: "Couldn't finish pairing",
                                eyebrowSymbol: "exclamationmark.triangle.fill",
                                eyebrowTint: LuminousPalette.amber,
                                subtitle: nil)
            LuminousNotice(text: message, symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber)
            VStack(spacing: 12) {
                LuminousPrimaryButton(title: "Try Again", symbol: "arrow.clockwise") {
                    vm.resetToIdle()
                }
                LuminousSecondaryButton(title: "Enter IP Manually", symbol: "keyboard") {
                    vm.resetToIdle()
                    showManualEntry = true
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Demo

    private var demoButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { onDemo?() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold))
                Text("Explore Demo")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
            }
            .foregroundStyle(LuminousPalette.cyan)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(LuminousPressStyle())
        .accessibilityHint("Try the app with a sample home — no bridge needed")
    }

    // MARK: - Manual IP Sheet

    private var manualIPSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LuminousScreenTitle(title: "Enter bridge IP",
                                        eyebrow: "Manual connection",
                                        eyebrowSymbol: "keyboard",
                                        eyebrowTint: LuminousPalette.cyan,
                                        subtitle: "Find your bridge IP in the Philips Hue app under Settings → My Hue System → Hue Bridges.")

                    TextField("192.168.1.100", text: $manualIP)
                        // numbersAndPunctuation, not decimalPad — the pad has no
                        // Return key, stranding the user (StageSlider precedent).
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($manualIPFocused)
                        .submitLabel(.go)
                        .onSubmit { connectManualIP() }
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(LuminousPalette.ink)
                        .padding(16)
                        .luminousGlass(radius: 16, accent: LuminousPalette.cyan, selected: manualIPFocused)
                        .onAppear { manualIPFocused = true }
                        .onChange(of: manualIP) { manualIPError = nil }

                    if let manualIPError {
                        LuminousNotice(text: manualIPError, symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber)
                    }

                    LuminousPrimaryButton(title: "Connect", symbol: "link") {
                        connectManualIP()
                    }
                    .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(HueSpacing.screenH)
            }
            .background { LuminousAmbience(colors: [LuminousPalette.cyan]) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
            }
        }
        .luminousSheet()
    }

    /// Shared by the Connect button and the keyboard's Go key.
    private func connectManualIP() {
        let raw = manualIP.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // L-16: only a syntactically valid IPv4/IPv6/hostname may enter the
        // pairing flow — a typo dies here with guidance, not as a hung probe.
        guard let host = BridgeEndpoint.validatedManualHost(raw) else {
            manualIPError = "That doesn't look like a bridge address. Double-check the numbers — it usually looks like 192.168.1.100."
            return
        }
        manualIPError = nil
        let bridge = BridgeEndpoint(name: "Hue Bridge", host: host, port: 443)
        showManualEntry = false
        vm.phase = .bridgeFound(bridge)
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
                .foregroundStyle(LuminousPalette.inkTertiary)
                .frame(minHeight: 44)
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
            // The registrar moved a FULL owner key onto what may have been a
            // guest-held record; its grant must go, or the stale allowlist
            // keeps filtering rooms and refusing owner actions.
            if Self.dropGuestGrantAfterOwnerPairing(registration, modelContext: modelContext) {
                orchestrator.updateGuestGrants(from: modelContext)
            }
        } catch {
            vm.phase = .error("Pairing succeeded but the bridge could not be saved — please try pairing again.\n(\(error.localizedDescription))")
        }
    }

    /// A link-button pairing is an OWNER credential. When the registrar
    /// reused a record this phone held as a guest (same bridgeid), delete that
    /// record's guest grant. Invite joins never come through here (they use
    /// GuestInviteAcceptor), so this cannot strip a legitimate grant.
    /// Returns true when a grant was removed.
    @discardableResult
    static func dropGuestGrantAfterOwnerPairing(
        _ registration: BridgePairingRegistrar.Registration,
        modelContext: ModelContext
    ) -> Bool {
        guard registration.reusedExistingRecord,
              (try? GuestAccessGrantStore.grant(for: registration.record.id,
                                                modelContext: modelContext)) != nil
        else { return false }
        return (try? GuestAccessGrantStore.deleteGrant(for: registration.record.id,
                                                       modelContext: modelContext)) != nil
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
