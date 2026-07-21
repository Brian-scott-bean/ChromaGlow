// NowPlayingBar.swift
// ChromaGlow — UI/Music (music integration R2)
//
// The Now Playing strip: artwork, track/artist, live beat chip, transport,
// and "Use album colors". Two styles — .full rides Studio's bottom inset
// via StudioMusicWiring; .compact sits on the Dashboard next to the
// effects now-playing bar (siblings — the effect registry and the music
// session never merge state). StageKit visual language throughout; every
// animation defers to \.isTabActive.

import SwiftUI

// MARK: - MusicNowPlayingBar

struct MusicNowPlayingBar: View {
    enum Style { case full, compact }

    var style: Style = .full
    /// Present when a palette is extractable AND a look is running to paint.
    var onUseAlbumColors: (() -> Void)? = nil
    var onOpenPicker: (() -> Void)? = nil

    @Environment(MusicSessionCoordinator.self) private var music
    @Environment(\.isTabActive) private var isTabActive

    var body: some View {
        HStack(spacing: 10) {
            artworkThumb
            titleBlock
            Spacer(minLength: 6)
            BeatStatusChip(compact: true)
                .fixedSize()   // "96" must never compress to "…"
            if music.capabilities.contains(.transport) {
                transportButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, style == .full ? 10 : 8)
        .contentShape(Rectangle())
        // The bar itself opens the source picker (buttons win hit-testing);
        // a dedicated picker button starved the title of width.
        .onTapGesture { onOpenPicker?() }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(StagePalette.raised.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StagePalette.line, lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityHint(onOpenPicker != nil ? "Double-tap to change the music source" : "")
    }

    // MARK: Pieces

    /// The album art doubles as the "Use album colors" control — the thumb
    /// already previews the extracted palette; tapping paints the running
    /// look with it (mini-player idiom: no room for a labeled button).
    private var artworkThumb: some View {
        Button {
            onUseAlbumColors?()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(thumbFill)
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if canApplyPalette {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(3)
                        .background(Circle().fill(HuePalette.amber))
                        .offset(x: 5, y: 5)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canApplyPalette)
        .accessibilityLabel(canApplyPalette ? "Use album colors" : "Album art")
    }

    private var canApplyPalette: Bool {
        onUseAlbumColors != nil && music.artworkPalette != nil
    }

    /// Album colors when we have them — the thumb IS the palette preview.
    private var thumbFill: LinearGradient {
        if let palette = music.artworkPalette {
            let c1 = HueColorUtils.color(fromX: palette.color1.x, y: palette.color1.y, brightness: 80)
            let c2 = HueColorUtils.color(fromX: palette.color2.x, y: palette.color2.y, brightness: 70)
            return LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [StagePalette.surface, StagePalette.raised],
                              startPoint: .top, endPoint: .bottom)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.nowPlaying?.title ?? "Nothing playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StagePalette.ink)
                .lineLimit(1)
            Text(subtitleText)
                .font(.system(size: 11))
                .foregroundStyle(StagePalette.muted)
                .lineLimit(1)
        }
    }

    private var subtitleText: String {
        guard let track = music.nowPlaying else { return "Pick a source to sync your lights" }
        switch track.service {
        case .demo: return "\(track.artist) · Sample track"
        case .appleMusic: return "\(track.artist) · Apple Music"
        case .shazamDetected: return "\(track.artist) · Heard nearby"
        case .spotify: return "\(track.artist) · Spotify"
        }
    }

    /// Mini-player transport: play/pause + next (the Music-app idiom —
    /// previous-track doesn't earn its 44 points here).
    private var transportButtons: some View {
        HStack(spacing: 0) {
            iconButton(music.isPlaying ? "pause.fill" : "play.fill",
                       label: music.isPlaying ? "Pause" : "Play") {
                Task { await music.transport(.togglePlayPause) }
            }
            if style == .full {
                iconButton("forward.fill", label: "Next track") {
                    Task { await music.transport(.nextTrack) }
                }
            }
        }
    }

    /// 44pt targets (Round-A class-wide rule) with compact visuals.
    private func iconButton(_ systemName: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StagePalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - StudioMusicWiring

/// Studio's music mount — one `.modifier(StudioMusicWiring(vm:))` line on
/// StudioView.body (which sits at the type-checker ceiling; extend THIS,
/// never the body chain). Shows the full bar during a session, a slim
/// "Sync to music" affordance otherwise, and owns the source-picker sheet.
struct StudioMusicWiring: ViewModifier {
    let vm: StudioViewModel

    @Environment(MusicSessionCoordinator.self) private var music
    @State private var showSourcePicker = false

    /// Height contention is real on small phones: hide the bar while the
    /// mixer tray is up on ≤700pt screens (the isCompactStudio boundary).
    private var suppressedForCompactMixer: Bool {
        vm.currentRoomEffect != nil && UIScreen.main.bounds.height <= 700
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
            .sheet(isPresented: $showSourcePicker) {
                MusicSourcePicker()
            }
    }

    @ViewBuilder
    private var bottomInset: some View {
        if !suppressedForCompactMixer {
            Group {
                if music.hasSession {
                    MusicNowPlayingBar(
                        style: .full,
                        onUseAlbumColors: paletteAction,
                        onOpenPicker: { showSourcePicker = true }
                    )
                } else {
                    syncToMusicPill
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var paletteAction: (() -> Void)? {
        guard vm.activeCompositionBox != nil else { return nil }
        return { applyAlbumPalette() }
    }

    private var syncToMusicPill: some View {
        Button {
            showSourcePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                Text("Sync to music")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(StagePalette.muted)
            .padding(.horizontal, 14)
            .frame(height: 44)   // full-size target, slim look
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(.white.opacity(0.05))
                .overlay(Capsule().stroke(StagePalette.line, lineWidth: 1))
                .frame(height: 32)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The one sanctioned palette write path: through the live editor box,
    /// exactly like the harmony onChange (never a parallel bridge write).
    private func applyAlbumPalette() {
        guard let palette = music.artworkPalette,
              let box = vm.activeCompositionBox else { return }
        if box.palette.mode != palette.mode { box.palette.mode = palette.mode }
        box.palette.color1 = palette.color1
        box.palette.color2 = palette.color2
        box.palette.color3 = palette.color3
        box.palette.harmonyRule = nil
        box.triggerRESTBurst()
    }
}
