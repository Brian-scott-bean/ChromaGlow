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
/// never the body chain). Always shows the full bar and owns the
/// source-picker sheet; without a session the bar reads "Nothing playing —
/// pick a source" (the earlier slim pill was too subtle to find).
struct StudioMusicWiring: ViewModifier {
    let vm: StudioViewModel

    @Environment(MusicSessionCoordinator.self) private var music
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var showSourcePicker = false

    private var suppressedForCompactMixer: Bool {
        StudioMusicWiring.barSuppressed(currentRoomEffect: vm.currentRoomEffect)
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
                MusicNowPlayingBar(
                    style: .full,
                    onUseAlbumColors: music.hasSession ? paletteAction : nil,
                    onOpenPicker: { showSourcePicker = true }
                )
            }
            .padding(.horizontal, 16)
            // The floating HueTabBar capsule is invisible to the safe-area
            // system (MainTabView's 64pt clear inset does not reach this
            // safeAreaInset — the bar rendered INSIDE the capsule's band,
            // pixel-verified). Clear the band explicitly, same discipline
            // as studioTabBarClearance everywhere else in Studio.
            .padding(.bottom, 70)
        }
    }

    private var paletteAction: (() -> Void)? {
        guard vm.activeCompositionBox != nil else { return nil }
        // A bridge-stored room has no live loop reading the box — the
        // paint badge there would invite a tap that does nothing (the
        // schedule plays on the bridge hardware). Audit R9, F10.
        if let roomID = vm.selectedRoom?.id,
           orchestrator.compositionTransportByRoom[roomID] == .bridgeStored {
            return nil
        }
        return { applyAlbumPalette() }
    }

    /// The one sanctioned palette write path: through the live editor box,
    /// exactly like the harmony onChange (never a parallel bridge write).
    private func applyAlbumPalette() {
        guard let palette = music.artworkPalette,
              let box = vm.activeCompositionBox else { return }
        // commitSwatchEdit's clamp discipline: the extractor emits gamut-C
        // points; the running room may be gamut A/B (audit R9, F7).
        let gamut = vm.activeCompositionGamut
        func clamped(_ c: CodableColor) -> CodableColor {
            let xy = HueColorUtils.clampXYToGamut(x: c.x, y: c.y, gamut: gamut)
            return CodableColor(x: xy.x, y: xy.y)
        }
        if box.palette.mode != palette.mode { box.palette.mode = palette.mode }
        box.palette.color1 = clamped(palette.color1)
        box.palette.color2 = clamped(palette.color2)
        box.palette.color3 = palette.color3.map(clamped)
        box.palette.harmonyRule = nil
        // Clear the harmony CHIP too — a lit rule re-imposes itself on the
        // next pad drag and overwrites these colors (audit R9, F6). The
        // `.none` sentinel rides the existing restoredHarmonyRule chain;
        // StudioView's onChange arms the echo guard so its destructive
        // `.none` branch can't fire on the fresh palette.
        if vm.restoredHarmonyRule != HarmonyRule.none {
            // The CASE, not Optional.none — bare `.none` on the optional
            // assigned nil, and from an already-nil state (rule picked by
            // hand, then album tapped) nil→nil never fired the onChange,
            // so the chip stayed lit and the next pad drag re-imposed the
            // rule over the album colors.
            vm.restoredHarmonyRule = HarmonyRule.none
        }
        box.triggerRESTBurst()
    }
}

// MARK: - Bar mounting

extension StudioMusicWiring {
    /// Single source of truth for "is Studio's music bar mounted?" — the bar
    /// itself, Studio's bottom clearance, and the mixer tray's clearance all
    /// read this. Height contention is real on small phones: the bar hides
    /// while the mixer tray is up on ≤700pt screens (the isCompactStudio
    /// boundary). Three hand-copied versions of this predicate used to sit in
    /// two files under a "keep in lockstep" comment.
    static func barSuppressed(currentRoomEffect: RunningEffect?) -> Bool {
        currentRoomEffect != nil && UIScreen.main.bounds.height <= 700
    }
}
