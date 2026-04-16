// SettingsView.swift
// HueHome Pro — Epic 7 / Story 7.1
//
// Glassmorphic settings sheet: bridge info, connection ping, token display,
// "Forget Bridge" (destructive), and app version.
// Presented as a .sheet from the Dashboard toolbar ⚙ button.

import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {

    let onForget: () -> Void          // caller handles dismiss after clearing Keychain

    // Loaded from Keychain on appear
    @State private var bridgeIP     = "—"
    @State private var tokenPreview = "—"
    @State private var pingStatus: PingStatus = .unknown

    @State private var showForgetAlert = false
    @Environment(\.dismiss) private var dismiss

    private let glowColor = Color(red: 1.0, green: 0.76, blue: 0.2)

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        bridgeSection
                        accountSection
                        appSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(glowColor)
                        .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
            .alert("Forget Bridge?", isPresented: $showForgetAlert) {
                Button("Forget", role: .destructive) {
                    // Clear Keychain directly in the non-escaping button action
                    try? KeychainManager.shared.deleteAPIToken()
                    try? KeychainManager.shared.deleteBridgeIP()
                    try? KeychainManager.shared.delete(for: "hue_client_key")
                    dismiss()     // close this sheet
                    onForget()    // signal parent to pop nav stack back to pairing
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved Bridge IP and API token will be removed. You'll need to press the link button again to re-pair.")
            }
            .onAppear { loadCredentials() }
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

    // ──────────────────────────────────────────────
    // MARK: - Bridge Section
    // ──────────────────────────────────────────────

    private var bridgeSection: some View {
        settingsGroup(header: "BRIDGE") {
            // IP row
            settingsRow(
                icon: "network",
                iconColor: glowColor,
                title: "Bridge IP",
                value: bridgeIP
            )

            Divider().background(Color.white.opacity(0.08))

            // Ping / connection status row
            HStack(spacing: 12) {
                iconCircle("wifi", color: pingColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Text(pingLabel)
                        .font(.caption)
                        .foregroundStyle(pingColor.opacity(0.85))
                }

                Spacer()

                Button {
                    pingStatus = .checking
                    Task { await pingBridge() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(pingStatus == .checking ? 360 : 0))
                        .animation(
                            pingStatus == .checking
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: pingStatus == .checking
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
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

            Divider().background(Color.white.opacity(0.08))

            // Forget Bridge — destructive
            Button {
                showForgetAlert = true
            } label: {
                HStack(spacing: 12) {
                    iconCircle("link.badge.minus", color: .red)

                    Text("Forget Bridge")
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
                    Text("HueHome Pro")
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
    // MARK: - Ping Status
    // ──────────────────────────────────────────────

    enum PingStatus: Equatable { case unknown, checking, reachable, unreachable }

    private var pingColor: Color {
        switch pingStatus {
        case .reachable:   return .green
        case .unreachable: return .red
        case .checking:    return glowColor
        case .unknown:     return .white.opacity(0.35)
        }
    }

    private var pingLabel: String {
        switch pingStatus {
        case .reachable:   return "Connected"
        case .unreachable: return "Unreachable"
        case .checking:    return "Checking…"
        case .unknown:     return "Tap ↺ to check"
        }
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
        bridgeIP     = (try? KeychainManager.shared.loadBridgeIP()) ?? "Not saved"
        let raw      = (try? KeychainManager.shared.loadAPIToken()) ?? ""
        tokenPreview = raw.isEmpty ? "Not saved"
                     : String(raw.prefix(6)) + "••••••" + String(raw.suffix(4))
        // Auto-ping on appear
        pingStatus = .checking
        Task { await pingBridge() }
    }

    private func pingBridge() async {
        guard let ip = try? KeychainManager.shared.loadBridgeIP(), !ip.isEmpty else {
            pingStatus = .unreachable; return
        }
        do {
            _ = try await HueAPIClient.shared.fetchRooms()
            pingStatus = .reachable
        } catch {
            pingStatus = .unreachable
        }
    }
}
