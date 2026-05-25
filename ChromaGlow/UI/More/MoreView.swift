// MoreView.swift
// ChromaGlow — v0.15.0 More Tab
//
// Power-user hub: Automations, Devices, Profiles, Bridge Manager, Settings.
// Full implementation in v0.16.0. This file is a routed stub that compiles.

import SwiftUI

// MARK: - MoreView

struct MoreView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showSettings      = false
    @State private var showAutomations   = false
    @State private var showDevices       = false

    // ── Accent colors (from design token system) ────────────
    private let purple = Color(hex: "#8C59FF")  // no token yet
    private let teal   = Color(hex: "#40D9BF")  // no token yet
    private let blue   = Color(hex: "#668AFF")  // no token yet

    var body: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    controlSection
                    peopleSection
                    systemSection
                    appSection
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.xxl)
                .padding(.bottom, 80)
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .navigationDestination(isPresented: $showAutomations) { AutomationsView() }
        .navigationDestination(isPresented: $showDevices)     { DevicesView() }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            HuePalette.Noir.background.ignoresSafeArea()
            Circle()
                .fill(RadialGradient(colors: [HuePalette.amber.opacity(0.14), .clear],
                                     center: .center, startRadius: 0, endRadius: 200))
                .frame(width: 340)
                .offset(x: 100, y: -200)
                .blur(radius: 20)
            Circle()
                .fill(RadialGradient(colors: [purple.opacity(0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 260)
                .offset(x: -120, y: 140)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Sections
    // ──────────────────────────────────────────────

    private var controlSection: some View {
        moreGroup(header: "CONTROL") {
            moreRow(icon: "bolt.fill", iconColor: purple,
                    title: "Automations",
                    subtitle: "Schedules, wake-up, and routines") {
                showAutomations = true
            }
            moreDivider
            moreRow(icon: "sensor.fill", iconColor: teal,
                    title: "Devices & Firmware",
                    subtitle: "\(orchestrator.totalLightCount) lights and sensors") {
                showDevices = true
            }
            moreDivider
            moreRow(icon: "switch.2", iconColor: blue,
                    title: "Accessories",
                    subtitle: "Buttons, remotes, and motion sensors",
                    badge: "Coming Soon") { }
        }
    }

    private var peopleSection: some View {
        moreGroup(header: "PEOPLE") {
            moreRow(icon: "person.2.fill", iconColor: HuePalette.amber,
                    title: "Profiles & Access",
                    subtitle: "Family and guest room control",
                    badge: "Coming Soon") { }
            moreDivider
            moreRow(icon: "qrcode", iconColor: HuePalette.amber,
                    title: "Share Invite",
                    subtitle: "Grant access via QR code",
                    badge: "Coming Soon") { }
        }
    }

    private var systemSection: some View {
        moreGroup(header: "SYSTEM") {
            NavigationLink(destination: BridgeManagerView()) {
                moreRowContent(
                    icon: "network", iconColor: HuePalette.amber,
                    title: "Bridge Manager",
                    subtitle: "\(orchestrator.activeBridgeCount) bridge\(orchestrator.activeBridgeCount == 1 ? "" : "s") connected"
                )
            }
            .buttonStyle(.plain)
            moreDivider
            // Live connection status (SSE-driven)
            liveConnectionRow
        }
    }

    private var appSection: some View {
        moreGroup(header: "APP") {
            // App identity row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#1F1A38"), Color(hex: "#141224")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(HuePalette.amber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChromaGlow")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Version \(appVersion) · Build \(buildNumber)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.40))
                }
                Spacer()
            }

            moreDivider

            moreRow(icon: "gear", iconColor: .white.opacity(0.5),
                    title: "Settings",
                    subtitle: "Bridge, API, and developer options") {
                showSettings = true
            }

            moreDivider

            // Demo mode toggle
            Button {
                if orchestrator.isDemoMode {
                    NotificationCenter.default.post(name: .hueDemoExited, object: nil)
                } else {
                    orchestrator.enterDemoMode()
                }
            } label: {
                moreRowContent(
                    icon: orchestrator.isDemoMode ? "sparkles.slash" : "sparkles",
                    iconColor: orchestrator.isDemoMode ? .orange : HuePalette.amber,
                    title: orchestrator.isDemoMode ? "Exit Demo Mode" : "Demo Mode",
                    subtitle: orchestrator.isDemoMode ? "Resume real bridge" : "Explore with mock data",
                    badge: orchestrator.isDemoMode ? "LIVE" : nil,
                    badgeColor: .orange
                )
            }
            .buttonStyle(.plain)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Connection Row
    // ──────────────────────────────────────────────

    private var liveConnectionRow: some View {
        let statuses  = orchestrator.connectionStatus
        let connected = statuses.values.filter { if case .connected = $0 { return true }; return false }.count
        let total     = statuses.count
        let color: Color = {
            if total == 0         { return .white.opacity(0.35) }
            if connected == total { return .green }
            if connected == 0     { return .red }
            return .orange
        }()
        let label: String = {
            if total == 0         { return "No bridges configured" }
            if connected == total { return "All \(total) bridge\(total == 1 ? "" : "s") connected" }
            return "\(connected) of \(total) connected"
        }()

        return HStack(spacing: 12) {
            iconCircle("wifi", color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(color.opacity(0.85))
            }
            Spacer()
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Reusable Primitives
    // ──────────────────────────────────────────────

    private var moreDivider: some View {
        Divider().background(Color.white.opacity(0.08))
    }

    private func moreGroup<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let built = content()
        return VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 4)

            GlassmorphicCard(isActive: false, glowColor: HuePalette.amber) {
                VStack(spacing: 12) { built }
            }
        }
    }

    @discardableResult
    private func moreRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        badge: String? = nil,
        badgeColor: Color = HuePalette.amber,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            moreRowContent(icon: icon, iconColor: iconColor,
                           title: title, subtitle: subtitle,
                           badge: badge, badgeColor: badgeColor)
        }
        .buttonStyle(.plain)
    }

    private func moreRowContent(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        badge: String? = nil,
        badgeColor: Color = HuePalette.amber
    ) -> some View {
        HStack(spacing: 12) {
            iconCircle(icon, color: iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(badgeColor.opacity(0.15)))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .contentShape(Rectangle())
    }

    private func iconCircle(_ name: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 36, height: 36)
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
