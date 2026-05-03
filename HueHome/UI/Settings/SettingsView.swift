// SettingsView.swift
// HueHome Pro — Epic 7 / Story 7.1
//
// Glassmorphic settings sheet: bridge info, connection ping, token display,
// "Forget Bridge" (destructive), and app version.
// Presented as a .sheet from the Dashboard toolbar ⚙ button.

import SwiftUI
import SwiftData

// MARK: - SettingsView

struct SettingsView: View {

    let onForget: () -> Void          // caller handles dismiss after clearing Keychain

    @Environment(\.modelContext)           private var modelContext
    @Environment(\.dismiss)               private var dismiss
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Query private var bridges: [BridgeRecord]

    // Loaded from Keychain on appear
    @State private var tokenPreview = "—"

    @State private var showForgetAlert = false

    private let glowColor = Color(red: 1.0, green: 0.76, blue: 0.2)

    // MARK: - Body

    var body: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    bridgesSection       // multi-bridge management + connection info
                    exploreSection       // Automations + Devices (moved from tab bar)
                    accountSection
                    developerSection
                    appSection
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
                // 3. Save SwiftData changes
                try? modelContext.save()
                // 4. Stop SSE connections
                orchestrator.stopSSE()
                onForget()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(bridges.count) bridge(s) will be removed. You'll need to press the link button on each bridge to re-pair.")
        }
        .onAppear { loadCredentials() }
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

    // ──────────────────────────────────────────────
    // MARK: - Explore Section (Automations + Devices)
    // ──────────────────────────────────────────────

    private var exploreSection: some View {
        settingsGroup(header: "EXPLORE") {
            NavigationLink(destination: AutomationsView()) {
                HStack(spacing: 12) {
                    iconCircle("bolt.fill", color: Color(red: 0.55, green: 0.35, blue: 1.0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automations")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text("Schedules, wake-up, and routines")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.08))

            NavigationLink(destination: DevicesView()) {
                HStack(spacing: 12) {
                    iconCircle("sensor.fill", color: Color(red: 0.25, green: 0.85, blue: 0.75))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Devices & Firmware")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text("All paired bulbs, switches, and sensors")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Bridges Section
    // ──────────────────────────────────────────────

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
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Developer Section
    // ──────────────────────────────────────────────

    private var developerSection: some View {
        settingsGroup(header: "DEVELOPER") {
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
                             : "Explore the app with mock data")
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
            }
            .buttonStyle(.plain)
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
                title: "API Token",
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
                    Text("CastChroma")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Version \(appVersion)  ·  Build \(buildNumber)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                }

                Spacer()
            }

            Divider().background(Color.white.opacity(0.08))

            HStack {
                Text("Philips Hue V2 API")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("clip/v2")
                    .font(.system(.caption, design: .monospaced))
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func loadCredentials() {
        let raw      = (try? KeychainManager.shared.loadAPIToken()) ?? ""
        tokenPreview = raw.isEmpty ? "Not saved"
                     : String(raw.prefix(6)) + "••••••" + String(raw.suffix(4))
    }
}
