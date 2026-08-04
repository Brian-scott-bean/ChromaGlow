// SettingsView.swift
// CastChroma — Epic 7 / Story 7.1
//
// Glassmorphic settings sheet: bridge info, connection ping, token display,
// "Forget Bridge" (destructive), and app version.
// Presented as a .sheet from the Dashboard toolbar ⚙ button.

import SwiftUI
import SwiftData
import CoreLocation
import WidgetKit

// MARK: - CleanBridgeTarget

/// Which bridge a destructive sweep is allowed to touch.
///
/// Pure, so the rule can be proved without a view. The rule matters because
/// Clean Bridge Resources removes every ChromaGlow-created resource on the
/// bridge it targets — including other rooms' looks that are running right
/// now — and it previously targeted `registeredBridgeIDs.first`. Lowest-sorting
/// id is not an answer to "which of my bridges are you about to wipe?".
enum CleanBridgeTarget {

    /// The bridge to act on, or nil when the user has not said.
    ///
    /// One registered bridge is unambiguous and is chosen automatically.
    /// Several are not, and no default is invented — a selection is required,
    /// and a selection naming a bridge that is no longer registered is not one.
    ///
    /// PRE-CONFIRMATION ONLY (round 3). This answers "can a confirmation be
    /// phrased at all?" — it is a live computation over the current registry,
    /// and the registry can change while a dialog is up. The moment a
    /// destructive confirmation is shown, the id it names is FROZEN into
    /// `cleanBridgeFrozenID`; re-resolving from here under an open dialog is
    /// exactly how "Clean B?" silently retargeted to A when B dropped off
    /// with one bridge remaining.
    static func resolve(registered: [String], selected: String?) -> String? {
        if registered.count == 1 { return registered[0] }
        guard let selected, registered.contains(selected) else { return nil }
        return selected
    }

    /// Must the user be asked before the confirmation can even be phrased?
    static func needsChoice(registered: [String], selected: String?) -> Bool {
        registered.count > 1 && resolve(registered: registered, selected: selected) == nil
    }

    /// Re-check, at the moment of deletion, the exact id that was confirmed.
    ///
    /// A bridge can be forgotten or drop off the network between the tap and
    /// the delete. Re-resolving from scratch there could silently retarget
    /// another bridge, so the confirmed id is either still registered — and
    /// used — or nothing happens at all.
    static func revalidate(confirmed: String?, registered: [String]) -> String? {
        guard let confirmed, registered.contains(confirmed) else { return nil }
        return confirmed
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    let onForget: () -> Void          // caller handles dismiss after clearing Keychain

    @Environment(\.modelContext)           private var modelContext
    @Environment(\.dismiss)               private var dismiss
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Query private var bridges: [BridgeRecord]
    @AppStorage("app.allowLandscapeRotation") private var allowLandscapeRotation: Bool = false

    // Loaded from Keychain on appear
    @State private var tokenPreview = "—"

    @State private var showForgetAlert = false
    @State private var isCleaningBridge = false
    @State private var cleanBridgeResult: String? = nil
    @State private var showCleanBridgeConfirm = false
    @State private var showCleanBridgePicker = false
    @State private var cleanBridgeSelectedID: String? = nil
    /// The exact bridge the OPEN destructive confirmation is about — frozen
    /// BEFORE the dialog is shown, and the only id its title, message and
    /// destructive action may read. `cleanBridgeTargetID` is a live
    /// computation: with bridges A and B, picking B and then losing B off
    /// the network left `registered == [A]`, which resolve() auto-selects —
    /// so the open dialog silently re-rendered as "Clean A?" and the tap
    /// wiped the bridge the user never chose (round 3).
    @State private var cleanBridgeFrozenID: String? = nil

    private let glowColor = Color(red: 1.0, green: 0.76, blue: 0.2)

    // MARK: - Body

    var body: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    bridgesSection       // multi-bridge management + connection info
                    allDayScenesSection
                    accountSection
                    developerSection
                    appSection
                    buildMetadataFooter
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 80)  // extra bottom pad for tab bar
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20)) // amber
            }
        }
        .preferredColorScheme(.dark)
        .alert("Forget All Bridges?", isPresented: $showForgetAlert) {
            Button("Forget All", role: .destructive) {
                // 1. Wipe all per-bridge Keychain credentials
                for bridge in bridges {
                    KeychainManager.shared.deleteCredentials(for: bridge.id)
                    modelContext.delete(bridge)
                }
                // 2. Wipe legacy single-bridge Keychain keys
                try? KeychainManager.shared.deleteAPIToken()
                try? KeychainManager.shared.deleteBridgeIP()
                try? KeychainManager.shared.delete(for: "hue_client_key")
                // 2b. Wipe TLS identity pins (D-016) — also unblocks re-pairing
                // a bridge whose certificate legitimately changed.
                BridgePinStore.shared.removeAll()
                // 2c. Wipe the shared widget/Siri surface: room snapshot,
                // routing metadata, and the shared-Keychain credential blob
                // (M-02/D-018), then signal the watch to do the same (L-30 —
                // the explicit wc_unpaired flag is the unpaired signal).
                WidgetDataStore.shared.clearAll()
                WatchSessionManager.shared.push(rooms: [], zones: [], bridges: [:], unpaired: true)
                WidgetCenter.shared.reloadAllTimelines()
                // 2d. Purge the SwiftData room/scene cache — stale rows carry
                // the DELETED bridge ids, and a later re-pair would preload
                // them as dashboard rooms whose controls silently no-op.
                for cached in (try? modelContext.fetch(FetchDescriptor<HueLocalRoom>())) ?? [] {
                    modelContext.delete(cached)
                }
                for cached in (try? modelContext.fetch(FetchDescriptor<HueLocalScene>())) ?? [] {
                    modelContext.delete(cached)
                }
                // 3. Save SwiftData changes
                try? modelContext.save()
                // 4. Full in-memory teardown (clients/sessions/snapshots) and
                // leave to the splash from EVERY presentation path — clearing
                // only the Keychain left the app fully usable until relaunch.
                Task {
                    await orchestrator.forgetAllBridges()
                    NotificationCenter.default.post(name: .hueBridgeUnpaired, object: nil)
                    onForget()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(bridges.count) bridge(s) will be removed. You'll need to press the link button on each bridge to re-pair.")
        }
        .onAppear { loadCredentials() }
    }

    // ──────────────────────────────────────────────
    // MARK: - All Day Scenes Section
    // ──────────────────────────────────────────────

    private var allDayScenesSection: some View {
        settingsGroup(header: "ALL DAY") {
            NavigationLink(destination: AllDayScenesView()) {
                HStack(spacing: 12) {
                    iconCircle("sun.max.fill", color: glowColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Day Scenes")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text("Circadian lighting that follows sunrise & sunset")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [glowColor.opacity(0.14), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 340)
                .offset(x: 100, y: -200)
                .blur(radius: 20)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 1).opacity(0.12), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 260)
                .offset(x: -120, y: 140)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    private var bridgesSection: some View {
        settingsGroup(header: orchestrator.isDemoMode ? "DEMO MODE" : "BRIDGES") {
            if orchestrator.isDemoMode {
                Button {
                    NotificationCenter.default.post(name: .hueDemoExited, object: nil)
                } label: {
                    HStack(spacing: 12) {
                        iconCircle("sparkles", color: glowColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Exit Demo Mode")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            Text("Connect to a real Hue Bridge")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(glowColor.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // ── Manage Bridges link ────────────────────────────────────
                NavigationLink(destination: BridgeManagerView()) {
                    HStack(spacing: 12) {
                        iconCircle("network", color: glowColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manage Bridges")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            Text("\(bridges.count) registered  ·  \(orchestrator.activeBridgeCount) active")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().background(Color.white.opacity(0.08))

                // ── Live connection status (SSE-driven, always accurate) ──────
                liveConnectionRow

                Divider().background(Color.white.opacity(0.08))

                // ── Forget All Bridges (destructive) ─────────────────────
                Button {
                    showForgetAlert = true
                } label: {
                    HStack(spacing: 12) {
                        iconCircle("minus.circle.fill", color: .red)
                        Text("Forget All Bridges")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.45))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Developer Section
    // ──────────────────────────────────────────────

    private var developerSection: some View {
        settingsGroup(header: "ADVANCED") {
            Button {
                if orchestrator.isDemoMode {
                    NotificationCenter.default.post(name: .hueDemoExited, object: nil)
                } else {
                    orchestrator.enterDemoMode()
                }
            } label: {
                HStack(spacing: 12) {
                    iconCircle(
                        orchestrator.isDemoMode ? "sparkles.slash" : "sparkles",
                        color: orchestrator.isDemoMode ? .orange : glowColor
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orchestrator.isDemoMode ? "Exit Demo Mode" : "Preview Demo Mode")
                            .font(.subheadline)
                            .foregroundStyle(orchestrator.isDemoMode ? .orange : .white)
                        Text(orchestrator.isDemoMode
                             ? "Resume real bridge connection"
                             : "Explore the app with a sample home")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    // Live indicator
                    if orchestrator.isDemoMode {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.orange.opacity(0.15)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.08))

            // ── Clean Bridge Resources ───────────────────────────────
            //
            // Confirm first, and name the exact bridge. This sweeps every
            // ChromaGlow-created resource on that one bridge — including other
            // rooms' saved looks that are currently running — so a single
            // unguarded tap was too much power for a row whose subtitle said
            // only "tidy up".
            Button {
                // With several bridges the target must be named before the
                // confirmation can name it. Whichever way the confirmation is
                // reached, the id it will speak about is frozen FIRST — from
                // here on, the live registry has no say in what the open
                // dialog names or deletes.
                if needsBridgeChoice {
                    showCleanBridgePicker = true
                } else {
                    cleanBridgeFrozenID = cleanBridgeTargetID
                    showCleanBridgeConfirm = true
                }
            } label: {
                HStack(spacing: 12) {
                    iconCircle("trash.circle", color: Color(red: 1.0, green: 0.55, blue: 0.25))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean Bridge Resources")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text(cleanBridgeResult ?? "Tidy up leftover ChromaGlow animation data on your bridge")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if isCleaningBridge {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCleaningBridge || orchestrator.isDemoMode)
            .opacity(orchestrator.isDemoMode ? 0.4 : 1.0)
            // Which bridge? Asked before anything is confirmed, never guessed.
            .confirmationDialog(
                "Clean which bridge?",
                isPresented: $showCleanBridgePicker,
                titleVisibility: .visible
            ) {
                ForEach(orchestrator.registeredBridgeIDs, id: \.self) { id in
                    Button(orchestrator.bridgeLabel(for: id)) {
                        cleanBridgeSelectedID = id
                        // Frozen from the picker's exact tap — never
                        // re-derived while the confirmation is up.
                        cleanBridgeFrozenID = id
                        showCleanBridgeConfirm = true
                    }
                }
                Button("Cancel", role: .cancel) {
                    cleanBridgeSelectedID = nil
                    cleanBridgeFrozenID = nil
                }
            } message: {
                Text("Only the bridge you pick is changed.")
            }
            .confirmationDialog(
                "Clean \(orchestrator.bridgeLabel(for: cleanBridgeFrozenID ?? ""))?",
                isPresented: $showCleanBridgeConfirm,
                titleVisibility: .visible
            ) {
                // Title, message and the destructive action all read ONLY the
                // frozen id. Reading the live resolution here is the round-3
                // defect: selected B, B drops off, one bridge remains, and
                // the open dialog silently becomes "Clean A?" under the
                // user's finger. Revalidation before the delete still refuses
                // a frozen id that is gone — so that case deletes nothing.
                Button("Remove ChromaGlow Data", role: .destructive) {
                    let frozen = cleanBridgeFrozenID
                    Task { await cleanBridgeResources(confirmedBridgeID: frozen) }
                }
                Button("Cancel", role: .cancel) {
                    cleanBridgeSelectedID = nil
                    cleanBridgeFrozenID = nil
                }
            } message: {
                Text("This removes every look ChromaGlow saved to \(orchestrator.bridgeLabel(for: cleanBridgeFrozenID ?? "")), including any that are running right now in other rooms. Looks on your other bridges aren't touched.")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Account Section
    // ──────────────────────────────────────────────

    private var accountSection: some View {
        settingsGroup(header: "ACCOUNT") {
            // Token preview row
            settingsRow(
                icon: "key.fill",
                iconColor: Color(red: 0.5, green: 0.7, blue: 1.0),
                title: "Bridge Connection Key",
                value: tokenPreview
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - App Section
    // ──────────────────────────────────────────────

    private var appSection: some View {
        settingsGroup(header: "APP") {
            HStack(spacing: 12) {
                // App icon proxy
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.10, blue: 0.22),
                                Color(red: 0.08, green: 0.07, blue: 0.14)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(glowColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ChromaGlow")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Version \(BuildMetadata.current.marketingVersion) · Build \(BuildMetadata.current.buildNumber)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                }

                Spacer()
            }

            Divider().background(Color.white.opacity(0.08))

            Toggle(isOn: $allowLandscapeRotation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Landscape Rotation")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Text("Off keeps Studio locked to portrait by default.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(glowColor)

            Divider().background(Color.white.opacity(0.08))

            HStack {
                Text("Connection")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("Philips Hue Bridge")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.30))
            }

            Divider().background(Color.white.opacity(0.08))

            HStack {
                Text("Built with ♥ for Hue")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.30))
                Spacer()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Build metadata footer
    // ──────────────────────────────────────────────

    private var buildMetadataFooter: some View {
        let metadata = BuildMetadata.current
        return VStack(spacing: 4) {
            Text("Version \(metadata.marketingVersion) · Build \(metadata.buildNumber)")
            buildMetadataCommitLine(metadata)
            if let branchName = metadata.branchName {
                Text("Branch \(branchName)")
            }
            if let buildTimestamp = metadata.buildTimestamp {
                Text("Built \(buildTimestamp)")
            }
            if metadata.isDirty == true {
                Text("Working tree modified")
            }
            Text("ChromaGlow is an independent app and is not affiliated with, endorsed by, or a product of Signify (Philips Hue). Philips Hue is a trademark of Signify Holding.")
                .padding(.top, 2)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func buildMetadataCommitLine(_ metadata: BuildMetadata) -> some View {
        if let shortSHA = metadata.shortCommitSHA {
            HStack(spacing: 0) {
                Text("Commit ")
                Text(shortSHA)
                    .font(.system(.caption2, design: .monospaced))
            }
        } else {
            Text("Commit Unavailable")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Reusable Primitives
    // ──────────────────────────────────────────────

    private func settingsGroup<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Materialize the non-escaping content closure BEFORE it enters
        // GlassmorphicCard's stored (escaping) @ViewBuilder property.
        let built = content()
        return VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 4)

            GlassmorphicCard(isActive: false, glowColor: glowColor) {
                VStack(spacing: 10) {
                    built   // Value (not closure) — safe to capture in escaping context
                }
            }
        }
    }

    private func settingsRow(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            iconCircle(icon, color: iconColor)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func iconCircle(_ name: String, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 32, height: 32)
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Connection Status
    // ──────────────────────────────────────────────

    /// Reads orchestrator.connectionStatus (updated live by SSE) — no manual ping needed.
    private var liveConnectionRow: some View {
        let statuses  = orchestrator.connectionStatus
        let connected = statuses.values.filter { if case .connected = $0 { return true }; return false }.count
        let total     = statuses.count
        let color: Color = {
            if total == 0          { return .white.opacity(0.35) }
            if connected == total  { return .green }
            if connected == 0      { return .red }
            return .orange
        }()
        let label: String = {
            if total == 0 { return "No bridges configured" }
            if connected == total { return "All \(total) bridge\(total == 1 ? "" : "s") connected" }
            return "\(connected) of \(total) connected"
        }()

        return HStack(spacing: 12) {
            iconCircle("wifi", color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(color.opacity(0.85))
            }
            Spacer()
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func loadCredentials() {
        let raw      = (try? KeychainManager.shared.loadAPIToken()) ?? ""
        tokenPreview = raw.isEmpty ? "Not saved"
                     : String(raw.prefix(6)) + "••••••" + String(raw.suffix(4))
    }

    /// The bridge this action will actually affect.
    ///
    /// With ONE registered bridge there is no ambiguity, so it is chosen
    /// automatically. With several there is no defensible default: `.first` is
    /// whichever id sorts lowest, which is an arbitrary answer to "which of my
    /// bridges are you about to wipe?" — so the user must name it, and until
    /// they do this is nil and the action cannot run.
    ///
    /// Also not `HueAPIClient.shared`: that is whichever client was configured
    /// last, which on a two-bridge home need not be the one on screen.
    private var cleanBridgeTargetID: String? {
        CleanBridgeTarget.resolve(registered: orchestrator.registeredBridgeIDs,
                                  selected: cleanBridgeSelectedID)
    }

    private var needsBridgeChoice: Bool {
        CleanBridgeTarget.needsChoice(registered: orchestrator.registeredBridgeIDs,
                                      selected: cleanBridgeSelectedID)
    }

    @MainActor
    private func cleanBridgeResources(confirmedBridgeID: String?) async {
        isCleaningBridge = true
        cleanBridgeResult = nil
        defer {
            isCleaningBridge = false
            cleanBridgeSelectedID = nil
            cleanBridgeFrozenID = nil
        }

        // Revalidate the EXACT bridge that was confirmed. Between the tap and
        // this line a bridge can be removed or drop off the network, and a
        // destructive sweep must never re-resolve to "some other bridge" —
        // that is how the wrong home gets wiped.
        guard let bridgeID = CleanBridgeTarget.revalidate(
                confirmed: confirmedBridgeID,
                registered: orchestrator.registeredBridgeIDs),
              let api = orchestrator.hueClient(for: bridgeID) else {
            cleanBridgeResult = "✗ Couldn't confirm which bridge to clean — nothing was removed"
            return
        }
        let label = orchestrator.bridgeLabel(for: bridgeID)

        do {
            let v1Client = try api.makeV1Client()
            let engine = BridgeAnimationEngine()
            let report = await engine.purgeAllChromaGlowResources(v1Client: v1Client)

            // Forget ONLY the manifests whose resources are provably gone.
            // A manifest for something that may still be running is the only
            // record that could stop it later, so anything short of proof is
            // retained — the same rule the reconciler follows for an
            // unreadable bridge.
            let removed = orchestrator.forgetManifestsProvenRemoved(by: report, onBridge: bridgeID)

            if report.isComplete {
                cleanBridgeResult = report.totalDeleted == 0
                    ? "✓ Nothing left to clean on \(label)"
                    : "✓ Removed \(report.totalDeleted) item\(report.totalDeleted == 1 ? "" : "s") from \(label)"
            } else if report.failedDeletes > 0 {
                cleanBridgeResult =
                    "⚠ Removed \(report.totalDeleted) from \(label); \(report.failedDeletes) couldn't be removed"
            } else {
                // Something could not be listed, so its contents are unknown.
                // Claiming "nothing was removed" would be as wrong as claiming
                // success.
                cleanBridgeResult =
                    "⚠ Removed \(report.totalDeleted) from \(label); some items couldn't be checked"
            }
            _ = removed

            // Auto-clear only a clean result. A warning stays until it is read.
            if report.isComplete {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    cleanBridgeResult = nil
                }
            }
        } catch {
            cleanBridgeResult = "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - All Day Scenes (Settings)

private struct AllDayScenesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @AppStorage("allDayScenes.enabled") private var enabled: Bool = false
    @AppStorage("allDayScenes.anchor.lat") private var anchorLat: Double = .nan
    @AppStorage("allDayScenes.anchor.lon") private var anchorLon: Double = .nan
    @AppStorage("allDayScenes.anchor.tz") private var anchorTz: String = ""
    @AppStorage("allDayScenes.anchor.updatedAt") private var anchorUpdatedAt: Double = 0

    @State private var isRequestingLocation = false
    @State private var errorText: String? = nil

    private var hasAnchor: Bool {
        anchorLat.isFinite && anchorLon.isFinite && !anchorTz.isEmpty
    }

    private var anchorDate: Date? {
        anchorUpdatedAt > 0 ? Date(timeIntervalSince1970: anchorUpdatedAt) : nil
    }

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    headerCard
                    controlsCard
                    if let err = errorText {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 80)
            }
        }
        .navigationTitle("All Day Scenes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20))
            }
        }
        .preferredColorScheme(.dark)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Circadian Auto‑Pilot")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("A gentle all-day curve based on sunrise and sunset.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                livePill
            }

            Text("Uses a one-time location anchor to calculate daily solar times. Your location is not tracked continuously.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in
                    enabled = newValue
                    if newValue, let anchor = orchestrator.loadAllDayAnchor() {
                        orchestrator.startAllDayScenes(anchor: anchor)
                    } else if !newValue {
                        orchestrator.stopAllDayScenes()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable All Day Scenes")
                        .foregroundStyle(.white)
                    Text("Applies a slow, natural shift to your rooms, skipping any that are already playing something.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(Color(red: 1.0, green: 0.76, blue: 0.20))

            Divider().background(Color.white.opacity(0.10))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Location anchor")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(hasAnchor ? anchorSummary : "Not set")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await requestOneTimeLocation() }
                } label: {
                    if isRequestingLocation {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Text(hasAnchor ? "Refresh" : "Set")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.12))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var livePill: some View {
        let isRunning = enabled && hasAnchor
        return HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? HuePalette.Noir.success : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(isRunning ? "LIVE" : "OFF")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isRunning ? HuePalette.Noir.success : .white.opacity(0.45))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var anchorSummary: String {
        var parts: [String] = []
        parts.append(String(format: "%.2f, %.2f", anchorLat, anchorLon))
        parts.append(anchorTz)
        if let d = anchorDate {
            parts.append("Updated \(d.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func requestOneTimeLocation() async {
        errorText = nil
        isRequestingLocation = true
        defer { isRequestingLocation = false }

        do {
            let loc = try await OneShotLocation.request()
            let tz = TimeZone.current.identifier
            anchorLat = loc.coordinate.latitude
            anchorLon = loc.coordinate.longitude
            anchorTz = tz
            anchorUpdatedAt = Date().timeIntervalSince1970

            orchestrator.saveAllDayAnchor(lat: anchorLat, lon: anchorLon, timeZoneID: tz)
            if enabled, let anchor = orchestrator.loadAllDayAnchor() {
                orchestrator.startAllDayScenes(anchor: anchor)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - One-shot location helper

private enum OneShotLocation {
    enum LocationError: LocalizedError {
        case servicesDisabled
        case denied
        case failed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .servicesDisabled: return "Location Services are disabled."
            case .denied: return "Location permission was denied."
            case .failed: return "Could not fetch your location."
            case .timedOut: return "Location request timed out — try again."
            }
        }
    }

    /// M-12: strong references for the lifetime of the in-flight request.
    /// CLLocationManager.delegate is weak and both objects used to be
    /// function locals — in an optimized build ARC could release them at the
    /// first suspension point, so no callback ever fired and the continuation
    /// never resumed ("Set location" spun forever).
    @MainActor private static var activeRequest: (manager: CLLocationManager, delegate: Delegate)?

    @MainActor
    static func request(timeoutSeconds: Double = 15) async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else { throw LocationError.servicesDisabled }

        let mgr = CLLocationManager()
        let delegate = Delegate()
        mgr.delegate = delegate
        mgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers

        activeRequest = (mgr, delegate)
        defer { activeRequest = nil }

        // M-12: bounded — the UI must never hang on a callback that never
        // arrives. The delegate's gate makes timeout vs. callback resolution
        // race-safe (resume exactly once).
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            delegate.finish(.failure(LocationError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont

            switch mgr.authorizationStatus {
            case .notDetermined:
                mgr.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                mgr.requestLocation()
            case .restricted, .denied:
                delegate.finish(.failure(LocationError.denied))
            @unknown default:
                delegate.finish(.failure(LocationError.failed))
            }
        }
    }

    final class Delegate: NSObject, CLLocationManagerDelegate {
        var continuation: CheckedContinuation<CLLocation, Error>?
        private let gate = ContinuationGate()

        /// Resume the continuation exactly once (M-12: timeout races callbacks).
        func finish(_ result: Result<CLLocation, Error>) {
            guard gate.tryResume(), let cont = continuation else { return }
            continuation = nil
            switch result {
            case .success(let location): cont.resume(returning: location)
            case .failure(let error):    cont.resume(throwing: error)
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard continuation != nil else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .restricted, .denied:
                finish(.failure(LocationError.denied))
            case .notDetermined:
                break
            @unknown default:
                finish(.failure(LocationError.failed))
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            if let location = locations.first {
                finish(.success(location))
            } else {
                finish(.failure(LocationError.failed))
            }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            finish(.failure(error))
        }
    }
}
