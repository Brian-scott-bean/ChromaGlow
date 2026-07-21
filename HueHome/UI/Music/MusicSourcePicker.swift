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
            )
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
        "Pandora doesn't let apps connect directly — pick Microphone and ChromaGlow listens along instead."

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
            appleMusicAvailable: false,   // R3 flips this
            spotifyAvailable: false       // R5 flips this (FeatureFlags.spotifySource)
        )
    }

    private var activeKind: MusicSourceOption.Kind {
        switch music.activeService {
        case .demo: .demo
        case .appleMusic: .appleMusic
        case .spotify: .spotify
        case .shazamDetected, nil: .mic
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            sourceRow(option)
                            if index < options.count - 1 { divider }
                        }
                    }
                    .background(cardBackground)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $tempoLookupEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MusicSourceCatalog.tempoLookupTitle)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(StagePalette.ink)
                                Text(MusicSourceCatalog.tempoLookupFootnote)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StagePalette.muted)
                            }
                        }
                        .tint(HuePalette.amber)
                        .padding(14)
                    }
                    .background(cardBackground)

                    Text(MusicSourceCatalog.pandoraFootnote)
                        .font(.system(size: 11))
                        .foregroundStyle(StagePalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(StagePalette.stage)
            .navigationTitle("Music Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HuePalette.amber)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Rows

    private func sourceRow(_ option: MusicSourceOption) -> some View {
        Button {
            select(option.kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(activeKind == option.kind ? HuePalette.amber : StagePalette.muted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StagePalette.ink)
                    Text(option.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(StagePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if activeKind == option.kind {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(HuePalette.amber)
                }
            }
            .padding(14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(StagePalette.line).frame(height: 1).padding(.leading, 54)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(StagePalette.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StagePalette.line, lineWidth: 1))
    }

    private func select(_ kind: MusicSourceOption.Kind) {
        switch kind {
        case .mic:
            music.deactivate()   // mic reactivity is the shipped default path
        case .demo:
            Task { try? await music.activate(MockMusicSource()) }
        case .appleMusic, .spotify:
            break   // rows absent until R3/R5 wire their sources
        }
        dismiss()
    }
}
