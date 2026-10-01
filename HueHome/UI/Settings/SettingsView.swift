// SettingsView.swift
// ChromaGlow — Settings (Luminous).
//
// Bridges (manage, live connection, Forget All), All Day Scenes, the bridge
// key preview, Advanced (Demo Mode, Clean Bridge Resources), the app, and
// the build footer with the Signify non-affiliation line (required here and
// in More). Presented as a sheet from More.

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

/// Settings, in the Luminous language: glass groups over the dark room.
/// Presented as a sheet from More (it carries its own Done).
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

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                LuminousScreenTitle(title: "Settings",
                                    eyebrow: "ChromaGlow",
                                    eyebrowSymbol: "gearshape.fill",
                                    eyebrowTint: LuminousPalette.cyan,
                                    subtitle: "Bridges, all-day light, and the app itself.")
                bridgesSection       // multi-bridge management + connection info
                allDayScenesSection
                accountSection
                developerSection
                appSection
                buildMetadataFooter
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet], intensity: 0.6) }
        .luminousPageChrome(title: "Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(LuminousPalette.cyan)
            }
        }
        .luminousSheet()
        .alert("Forget All Bridges?", isPresented: $showForgetAlert) {
            Button("Forget All", role: .destructive) {
                // 0. Stop the orchestrator's debounced widget/watch publisher
                // FIRST — a publish landing between the wipe below and the
                // async teardown re-wrote the rooms and pushed the watch a
                // newer `wc_unpaired = false` context over the unpair.
                orchestrator.suspendWidgetPublishingForTeardown()
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
    // MARK: - Bridges
    // ──────────────────────────────────────────────

    private var bridgesSection: some View {
        LuminousGroup(title: orchestrator.isDemoMode ? "Demo Mode" : "Bridges") {
            if orchestrator.isDemoMode {
                Button {
                    NotificationCenter.default.post(name: .hueDemoExited, object: nil)
                } label: {
                    LuminousRow(symbol: "sparkles", tint: LuminousPalette.amber, title: "Exit Demo Mode",
                                subtitle: "Connect to a real Hue Bridge") {
                        LuminousTextBadge(text: "Live", tint: LuminousPalette.amber)
                    }
                }
                .buttonStyle(LuminousRowButtonStyle())
            } else {
                // ── Manage Bridges link ────────────────────────────────────
                NavigationLink(destination: BridgeManagerView()) {
                    LuminousRow(symbol: "network", tint: LuminousPalette.cyan, title: "Manage Bridges",
                                subtitle: "\(bridges.count) registered  ·  \(orchestrator.activeBridgeCount) active")
                }
                .buttonStyle(LuminousRowButtonStyle())
                LuminousRowDivider()
                // ── Live connection status (SSE-driven, always accurate) ──────
                liveConnectionRow
                LuminousRowDivider()
                // ── Forget All Bridges (destructive) ─────────────────────
                Button {
                    showForgetAlert = true
                } label: {
                    LuminousRow(symbol: "minus.circle.fill", tint: LuminousPalette.danger,
                                title: "Forget All Bridges",
                                subtitle: "Removes every bridge and its key from this phone",
                                subtitleTint: LuminousPalette.danger.opacity(0.8))
                }
                .buttonStyle(LuminousRowButtonStyle())
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - All Day Scenes Section
    // ──────────────────────────────────────────────

    private var allDayScenesSection: some View {
        LuminousGroup(title: "All Day") {
            NavigationLink(destination: AllDayScenesView()) {
                LuminousRow(symbol: "sun.max.fill", tint: Color(hex: "#FFD36B"), title: "All Day Scenes",
                            subtitle: "Circadian lighting that follows sunrise & sunset")
            }
            .buttonStyle(LuminousRowButtonStyle())
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Developer Section
    // ──────────────────────────────────────────────

    private var developerSection: some View {
        LuminousGroup(title: "Advanced") {
            // In Demo Mode the Bridges group above already carries Exit Demo
            // Mode — the same action twice on one screen was noise.
            if !orchestrator.isDemoMode {
                Button {
                    orchestrator.enterDemoMode()
                } label: {
                    LuminousRow(symbol: "sparkles", tint: LuminousPalette.cyan, title: "Preview Demo Mode",
                                subtitle: "Explore the app with a sample home")
                }
                .buttonStyle(LuminousRowButtonStyle())
                LuminousRowDivider()
            }

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
                LuminousRow(symbol: "trash.circle", tint: Color(hex: "#FF8C40"), title: "Clean Bridge Resources",
                            subtitle: cleanBridgeResult ?? "Tidy up leftover ChromaGlow animation data on your bridge") {
                    if isCleaningBridge {
                        ProgressView().tint(LuminousPalette.ink).scaleEffect(0.8)
                    } else {
                        LuminousChevron()
                    }
                }
            }
            .buttonStyle(LuminousRowButtonStyle())
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
        LuminousGroup(title: "Account") {
            LuminousRow(symbol: "key.fill", tint: LuminousPalette.violet, title: "Bridge Connection Key") {
                Text(tokenPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - App Section
    // ──────────────────────────────────────────────

    private var appSection: some View {
        LuminousGroup(title: "App") {
            LuminousAppIdentityRow()
            LuminousRowDivider(inset: 16)
            LuminousToggleRow(symbol: "rectangle.landscape.rotate", tint: LuminousPalette.cyan,
                              title: "Allow Landscape Rotation",
                              subtitle: "Off keeps Studio locked to portrait by default.",
                              isOn: $allowLandscapeRotation)
            LuminousRowDivider()
            HStack {
                Text("Connection")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                Spacer()
                Text("Philips Hue Bridge")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            LuminousRowDivider(inset: 16)
            HStack {
                Text("Built with ♥ for Hue")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
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
                .padding(.top, 6)
        }
        .font(.caption2)
        .foregroundStyle(LuminousPalette.inkTertiary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
        .padding(.horizontal, 12)
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
    // MARK: - Live Connection Status
    // ──────────────────────────────────────────────

    /// Reads orchestrator.connectionStatus (updated live by SSE) — no manual ping needed.
    private var liveConnectionRow: some View {
        let summary = BridgeConnectionSummary(orchestrator.connectionStatus)
        return LuminousRow(symbol: "wifi", tint: summary.tint, title: "Connection",
                           subtitle: summary.label, subtitleTint: summary.tint) {
            Circle()
                .fill(summary.tint)
                .frame(width: 8, height: 8)
                .shadow(color: summary.tint, radius: summary.isHealthy ? 4 : 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func loadCredentials() {
        // The key lives per bridge (Stage 2A). The legacy single-bridge
        // `hue_api_token` slot is deleted by the migration, so reading it
        // showed "Not saved" to every migrated or newly paired user. Show the
        // first active bridge's key (sort order), legacy slot as a fallback.
        let ordered = bridges.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.sortOrder < $1.sortOrder
        }
        let perBridge = ordered.lazy
            .compactMap { try? KeychainManager.shared.loadCredentials(for: $0.id).token }
            .first { !$0.isEmpty }
        let raw      = perBridge ?? (try? KeychainManager.shared.loadAPIToken()) ?? ""
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
    /// Also not the shared singleton client: that is whichever client was
    /// configured last, which on a two-bridge home need not be the one on
    /// screen.
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

    private let sun = Color(hex: "#FFD36B")

    private var hasAnchor: Bool {
        anchorLat.isFinite && anchorLon.isFinite && !anchorTz.isEmpty
    }

    private var anchorDate: Date? {
        anchorUpdatedAt > 0 ? Date(timeIntervalSince1970: anchorUpdatedAt) : nil
    }

    private var isRunning: Bool { enabled && hasAnchor }

    var body: some View {
        LuminousPage(title: "All Day Scenes",
                     eyebrow: "Circadian Auto‑Pilot",
                     eyebrowSymbol: "sun.max.fill",
                     tint: sun,
                     subtitle: "A gentle all-day curve based on sunrise and sunset.",
                     ambience: [sun, Color(hex: "#FF9F5C")]) {
            HStack(spacing: 10) {
                LuminousLiveBadge(state: isRunning ? .active : .paused, text: isRunning ? "Live" : "Off")
                Spacer(minLength: 0)
            }
            LuminousNotice(text: "Uses a one-time location anchor to calculate daily solar times. Your location is not tracked continuously.",
                           symbol: "location.circle.fill", tint: sun)
            controlsCard
            if let err = errorText {
                LuminousNotice(text: err, symbol: "exclamationmark.triangle.fill", tint: LuminousPalette.danger)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(LuminousPalette.cyan)
            }
        }
    }

    private var controlsCard: some View {
        LuminousGroup {
            LuminousToggleRow(symbol: "sun.horizon.fill", tint: sun, title: "Enable All Day Scenes",
                              subtitle: "Applies a slow, natural shift to your rooms, skipping any that are already playing something.",
                              isOn: Binding(
                                get: { enabled },
                                set: { newValue in
                                    enabled = newValue
                                    if newValue, let anchor = orchestrator.loadAllDayAnchor() {
                                        orchestrator.startAllDayScenes(anchor: anchor)
                                    } else if !newValue {
                                        orchestrator.stopAllDayScenes()
                                    }
                                }
                              ))
            LuminousRowDivider()
            LuminousRow(symbol: "location.fill", tint: LuminousPalette.cyan, title: "Location anchor",
                        subtitle: hasAnchor ? anchorSummary : "Not set") {
                Button {
                    Task { await requestOneTimeLocation() }
                } label: {
                    Group {
                        if isRequestingLocation {
                            ProgressView().tint(LuminousPalette.void).scaleEffect(0.8)
                        } else {
                            Text(hasAnchor ? "Refresh" : "Set")
                                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        }
                    }
                    .foregroundStyle(LuminousPalette.void)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(LuminousPalette.signalGradient))
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(LuminousPressStyle(scale: 0.93))
                .disabled(isRequestingLocation)
                .accessibilityLabel(hasAnchor ? "Refresh location anchor" : "Set location anchor")
            }
        }
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
