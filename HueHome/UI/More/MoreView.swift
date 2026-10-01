// MoreView.swift
// ChromaGlow — More (Luminous).
//
// The setup side of the home, in the same dark room as everything else:
// a connection chip, the title block, then four glass groups — what runs the
// lights (Control), who may use them (People), what they talk through
// (System) and the app itself (App). Rare tasks, so plain rows; every row
// opens exactly what it always did.
//
// Must stay here (App Store runbook / API terms): the Signify non-affiliation
// line in the identity row, and the GetSongBPM attribution backlink.

import SwiftUI

// MARK: - MoreView

struct MoreView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showSettings      = false
    @State private var replayTour: TourPresentation?
    @State private var showAutomations   = false
    @State private var showDevices       = false
    @State private var showEntertainmentAreas = false
    @State private var showShareInvite   = false

    // Row accents — the same three hues the Welcome Tour paints its pages in.
    private let purple = Color(hex: "#8C59FF")
    private let teal   = Color(hex: "#40D9BF")
    private let blue   = Color(hex: "#668AFF")

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                LuminousScreenTitle(title: "More",
                                    eyebrow: "Home setup",
                                    eyebrowSymbol: "gearshape.2.fill",
                                    eyebrowTint: LuminousPalette.violet,
                                    subtitle: summaryLine)
                controlSection
                peopleSection
                systemSection
                appSection
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { LuminousAmbience(colors: [LuminousPalette.violet, teal], intensity: 0.6) }
        .toolbar(.hidden, for: .navigationBar)
        // Names this screen to the back button of everything pushed from it.
        .navigationTitle("More")
        .preferredColorScheme(.dark)
        .navigationDestination(isPresented: $showAutomations) { AutomationsView() }
        .navigationDestination(isPresented: $showDevices)     { DevicesView() }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
        .sheet(isPresented: $showShareInvite) { ShareInviteSheet() }
        .fullScreenCover(item: $replayTour) { presentation in
            WelcomeTourView(pages: presentation.pages) {
                replayTour = nil
            }
        }
        // The app's always-reachable place to view, create, rename and delete
        // Entertainment Areas (the Composer's own prompt is conditional).
        .navigationDestination(isPresented: $showEntertainmentAreas) { EntertainmentAreasView() }
    }

    // MARK: - Header

    private var connection: BridgeConnectionSummary {
        BridgeConnectionSummary(orchestrator.connectionStatus)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if orchestrator.isDemoMode {
                LuminousStateChip(text: "Demo home", dot: LuminousPalette.cyan, glowing: true)
            } else {
                LuminousStateChip(text: connection.label, dot: connection.tint, glowing: connection.isHealthy)
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryLine: String {
        let bridges = orchestrator.activeBridgeCount
        let lights = orchestrator.totalLightCount
        let rooms = orchestrator.allRooms.count
        let home = "\(lights) light\(lights == 1 ? "" : "s") · \(rooms) room\(rooms == 1 ? "" : "s")"
        if orchestrator.isDemoMode { return "\(home) in the sample home" }
        return "\(bridges) bridge\(bridges == 1 ? "" : "s") · \(home)"
    }

    // MARK: - Sections

    private var controlSection: some View {
        LuminousGroup(title: "Control") {
            Button { showAutomations = true } label: {
                LuminousRow(symbol: "bolt.fill", tint: purple, title: "Automations",
                            subtitle: "Schedules, wake-up, and routines")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            Button { showDevices = true } label: {
                LuminousRow(symbol: "sensor.fill", tint: teal, title: "Devices & Updates",
                            subtitle: "\(orchestrator.totalLightCount) light\(orchestrator.totalLightCount == 1 ? "" : "s") · every device and its firmware")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            Button { showEntertainmentAreas = true } label: {
                LuminousRow(symbol: "dot.radiowaves.left.and.right", tint: LuminousPalette.cyan,
                            title: "Entertainment Areas",
                            subtitle: "View, create, and edit instant-response light zones")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            NavigationLink(destination: PhysicalControlsView()) {
                LuminousRow(symbol: "dial.medium.fill", tint: blue, title: "Physical Controls",
                            subtitle: "Tap Dial DJ Mode — set the beat by hand")
            }
            .buttonStyle(LuminousRowButtonStyle())
        }
    }

    private var peopleSection: some View {
        LuminousGroup(title: "People") {
            NavigationLink(destination: ProfilesAccessView()) {
                LuminousRow(symbol: "person.2.fill", tint: LuminousPalette.amber, title: "Profiles & Access",
                            subtitle: "Family and guest room control")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            Button { showShareInvite = true } label: {
                LuminousRow(symbol: "qrcode", tint: LuminousPalette.magenta, title: "Share Invite",
                            subtitle: "Grant access via QR code")
            }
            .buttonStyle(LuminousRowButtonStyle())
        }
    }

    private var systemSection: some View {
        LuminousGroup(title: "System") {
            NavigationLink(destination: BridgeManagerView()) {
                LuminousRow(symbol: "network", tint: LuminousPalette.cyan, title: "Bridge Manager",
                            subtitle: "\(orchestrator.activeBridgeCount) bridge\(orchestrator.activeBridgeCount == 1 ? "" : "s") connected")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            // Live connection status (SSE-driven) — information, not a door.
            LuminousRow(symbol: "wifi", tint: connection.tint, title: "Connection",
                        subtitle: connection.label, subtitleTint: connection.tint) {
                Circle()
                    .fill(connection.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: connection.tint, radius: connection.isHealthy ? 4 : 0)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var appSection: some View {
        LuminousGroup(title: "App") {
            // Identity + the Signify non-affiliation line (required here).
            LuminousAppIdentityRow(detail: "ChromaGlow is an independent app and is not affiliated with, endorsed by, or a product of Signify (Philips Hue). Philips Hue is a trademark of Signify Holding.")
            LuminousRowDivider(inset: 16)
            Button { showSettings = true } label: {
                LuminousRow(symbol: "gearshape.fill", tint: LuminousPalette.ink, title: "Settings",
                            subtitle: "Bridge and app options")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            Button {
                // Item-based cover: the pages snapshot rides the presentation,
                // so a mid-tour grant change can't reshuffle the deck.
                replayTour = TourPresentation(id: 1, pages: TutorialCatalog.pages(
                    includeStudioSuite: !(orchestrator.guestAccessInfo.isGuestOnly && !orchestrator.isDemoMode)))
            } label: {
                LuminousRow(symbol: "play.circle.fill", tint: teal, title: "Replay the Tour",
                            subtitle: "A two-minute tour of everything")
            }
            .buttonStyle(LuminousRowButtonStyle())
            LuminousRowDivider()
            // GetSongBPM attribution — REQUIRED by their API terms (free key
            // in exchange for a backlink; account suspended without it).
            Button {
                if let url = URL(string: "https://getsongbpm.com") {
                    UIApplication.shared.open(url)
                }
            } label: {
                LuminousRow(symbol: "metronome.fill", tint: LuminousPalette.amber, title: "Song Tempo Data",
                            subtitle: "Powered by GetSongBPM.com") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LuminousPalette.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(LuminousRowButtonStyle())
            .accessibilityHint("Opens getsongbpm.com")
            LuminousRowDivider()
            Button {
                if orchestrator.isDemoMode {
                    NotificationCenter.default.post(name: .hueDemoExited, object: nil)
                } else {
                    orchestrator.enterDemoMode()
                }
            } label: {
                LuminousRow(symbol: orchestrator.isDemoMode ? "sparkles.slash" : "sparkles",
                            tint: orchestrator.isDemoMode ? LuminousPalette.amber : LuminousPalette.cyan,
                            title: orchestrator.isDemoMode ? "Exit Demo Mode" : "Demo Mode",
                            subtitle: orchestrator.isDemoMode ? "Resume real bridge" : "Explore a sample home") {
                    if orchestrator.isDemoMode {
                        LuminousTextBadge(text: "Live", tint: LuminousPalette.amber)
                    } else {
                        LuminousChevron()
                    }
                }
            }
            .buttonStyle(LuminousRowButtonStyle())
        }
    }
}
