// MusicSourcePicker.swift
// ChromaGlow — UI/Music (music integration R2)
//
// The "where's your music coming from?" sheet. Row availability is a pure,
// tested catalog (MusicSourceCatalog); the sheet just renders it, activates
// the chosen source through MusicSessionCoordinator, and hosts the honest
// tempo-lookup toggle. Pandora gets the truth in the footer.

import SwiftUI

// MARK: - Catalog (pure, tested)

struct MusicSourceOption: Identifiable, Equatable {
    enum Kind: Equatable {
        case mic
        case shazam
        case demo
        case appleMusic
        case spotify
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String

    var id: String { title }
}

enum MusicSourceCatalog {
    /// Row availability truth. `isDemoMode`/`isSimulator` gate the sample
    /// track; Apple Music appears in R3, Spotify (dev-flagged) in R5.
    static func options(
        isDemoMode: Bool,
        isSimulator: Bool,
        appleMusicAvailable: Bool,
        spotifyAvailable: Bool
    ) -> [MusicSourceOption] {
        var rows: [MusicSourceOption] = [
            MusicSourceOption(
                kind: .mic,
                title: "Microphone",
                subtitle: "Listens in the room — works with anything playing out loud",
                icon: "mic.fill"
            ),
            MusicSourceOption(
                kind: .shazam,
                title: "Auto-Detect Song",
                subtitle: "Names whatever's playing nearby and matches the lights to its beat",
                icon: "waveform.and.magnifyingglass"
            ),
        ]
        if isDemoMode || isSimulator {
            rows.append(MusicSourceOption(
                kind: .demo,
                title: "Sample Track",
                subtitle: "A built-in song to see music sync in action",
                icon: "music.note"
            ))
        }
        if appleMusicAvailable {
            rows.append(MusicSourceOption(
                kind: .appleMusic,
                title: "Apple Music",
                subtitle: "Follows what you play in the Music app",
                icon: "music.note.house.fill"
            ))
        }
        if spotifyAvailable {
            rows.append(MusicSourceOption(
                kind: .spotify,
                title: "Spotify",
                subtitle: "Follows what you play in Spotify",
                icon: "waveform"
            ))
        }
        return rows
    }

    static let pandoraFootnote =
        "Pandora doesn't let apps connect directly — pick Auto-Detect Song and ChromaGlow listens along instead."

    static let tempoLookupTitle = "Look up song tempo"
    static let tempoLookupFootnote =
        "Finds a song's exact beat online for tighter light sync. Only the song's ID is sent — nothing about you. Turn it off and ChromaGlow listens for the beat instead."
}

// MARK: - Picker sheet

struct MusicSourcePicker: View {
    @Environment(MusicSessionCoordinator.self) private var music
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TrackTempoResolver.lookupEnabledKey) private var tempoLookupEnabled = true

    struct ActivationAlert: Identifiable {
        let title: String
        let message: String
        var id: String { title }
    }
    @State private var activationAlert: ActivationAlert?
    /// Overlapping activations were the fuel for the coordinator's
    /// supersede races (audit R9, F11 → F3/F4): a double-tap or a quick
    /// second pick while start() sat on a system prompt raced two
    /// sources. One activation at a time.
    @State private var isActivating = false

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private var options: [MusicSourceOption] {
        MusicSourceCatalog.options(
            isDemoMode: orchestrator.isDemoMode,
            isSimulator: isSimulator,
            appleMusicAvailable: true,    // R3: SystemMusicPlayer mirror
            spotifyAvailable: FeatureFlags.spotifySource && !SpotifyKeys.clientID.isEmpty
        )
    }

    private var activeKind: MusicSourceOption.Kind {
        switch music.activeService {
        case .demo: .demo
        case .appleMusic: .appleMusic
        case .spotify: .spotify
        case .shazamDetected: .shazam
        case nil: .mic
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LuminousScreenTitle(title: "Music Source",
                                        eyebrow: "Music",
                                        eyebrowSymbol: "music.note",
                                        eyebrowTint: LuminousPalette.magenta,
                                        subtitle: "Where the beat comes from — looks that dance follow it.")
                    LuminousGroup {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            sourceRow(option)
                            if index < options.count - 1 { LuminousRowDivider() }
                        }
                    }

                    #if CHROMAGLOW_EXPERIMENTAL_SPOTIFY
                    SpotifyConnectExperimentSection()
                    #endif

                    LuminousGroup(footer: MusicSourceCatalog.pandoraFootnote) {
                        LuminousToggleRow(symbol: "metronome.fill", tint: LuminousPalette.amber,
                                          title: MusicSourceCatalog.tempoLookupTitle,
                                          subtitle: MusicSourceCatalog.tempoLookupFootnote,
                                          isOn: $tempoLookupEnabled)
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background { LuminousAmbience(colors: [LuminousPalette.magenta, LuminousPalette.violet], intensity: 0.65) }
            .navigationTitle("Music Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
            .alert(item: $activationAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            }
        }
        .presentationDetents([.medium, .large])
        .luminousSheet()
    }

    // MARK: Rows

    private func sourceRow(_ option: MusicSourceOption) -> some View {
        let active = activeKind == option.kind
        return Button {
            select(option.kind)
        } label: {
            LuminousRow(symbol: option.icon,
                        tint: active ? LuminousPalette.magenta : LuminousPalette.inkSecondary,
                        title: option.title,
                        subtitle: option.subtitle) {
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LuminousPalette.magenta)
                        .shadow(color: LuminousPalette.magenta.opacity(0.6), radius: 6)
                        .accessibilityHidden(true)
                }
            }
            .background(active ? LuminousPalette.magenta.opacity(0.07) : .clear)
            .opacity(isActivating ? 0.5 : 1)
        }
        .buttonStyle(LuminousRowButtonStyle())
        .disabled(isActivating)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
        .contextMenu {
            // Recovery lever for a dead Spotify link (revoked refresh
            // token): without it, the only way out was clearing the
            // Keychain. Lazy closure — the Keychain read happens on
            // long-press, not per render.
            if option.kind == .spotify, SpotifyAuthService().isLinked {
                Button(role: .destructive) {
                    SpotifyAuthService().unlink()
                    if music.activeService == .spotify { music.deactivate() }
                } label: {
                    Label("Unlink Spotify", systemImage: "link.badge.minus")
                }
            }
        }
    }

    private func select(_ kind: MusicSourceOption.Kind) {
        guard !isActivating else { return }
        switch kind {
        case .mic:
            music.deactivate()   // mic reactivity is the shipped default path
            dismiss()
        case .demo:
            activate(MockMusicSource(), failureAlert: nil)
        case .appleMusic:
            activate(AppleMusicSource(), failureAlert: ActivationAlert(
                title: "Apple Music Access Needed",
                message: "Allow ChromaGlow to see what's playing in Apple Music. Nothing is played or changed without you."
            ))
        case .shazam:
            activate(ShazamSource(), failureAlert: ActivationAlert(
                title: "Microphone Access Needed",
                message: "Auto-Detect listens for the song playing nearby. Audio is analyzed on this phone and never recorded."
            ))
        case .spotify:
            activate(SpotifySource(), failureAlert: ActivationAlert(
                title: "Spotify Link Needed",
                message: "Finish the Spotify login to follow what you play. Heads-up: Spotify only allows accounts on this app's developer allowlist for now."
            ))
        }
    }

    /// One activation at a time; success dismisses, failure alerts (a nil
    /// alert means fire-and-dismiss — the demo source cannot fail).
    private func activate(_ source: any MusicSource, failureAlert: ActivationAlert?) {
        isActivating = true
        Task {
            defer { isActivating = false }
            do {
                try await music.activate(source)
                dismiss()
            } catch {
                if let failureAlert {
                    activationAlert = failureAlert
                } else {
                    dismiss()
                }
            }
        }
    }
}
