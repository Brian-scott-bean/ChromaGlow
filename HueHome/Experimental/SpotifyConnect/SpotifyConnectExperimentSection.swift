// SpotifyConnectExperimentSection.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment)
//
// The minimal experiment surface inside the Music Source sheet: choose what
// light sync analyzes (Microphone, or Spotify Connect — Experimental) and run
// the receiver. Everything shown is polled diagnostics from
// SpotifyConnectReceiver; the analyzer bars are AudioAnalysisEngine's own
// published bass/mid/high/overall — the values every Live look reads.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import SwiftUI

struct SpotifyConnectExperimentSection: View {
    @State private var sourceKind: AudioAnalysisSourceKind = .microphone
    @State private var isSwitching = false

    private var receiver: SpotifyConnectReceiver { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIGHT-SYNC AUDIO · EXPERIMENT")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(StagePalette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            sourceRow(.microphone,
                      title: "Microphone",
                      subtitle: "Listens in the room — the normal path",
                      icon: "mic.fill")
            divider
            sourceRow(.spotifyConnect,
                      title: "Spotify Connect — Experimental",
                      subtitle: "Pick “\(SpotifyConnectReceiver.deviceName)” in Spotify; lights read the stream itself",
                      icon: "dot.radiowaves.left.and.right")

            if sourceKind == .spotifyConnect {
                divider
                receiverBlock
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(StagePalette.surface)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StagePalette.line, lineWidth: 1))
        )
        .onAppear { sourceKind = AudioAnalysisEngine.shared.sourceKind }
    }

    // MARK: Source selector

    private var divider: some View {
        Rectangle().fill(StagePalette.line).frame(height: 1).padding(.leading, 54)
    }

    private func sourceRow(_ kind: AudioAnalysisSourceKind, title: String,
                           subtitle: String, icon: String) -> some View {
        Button { select(kind) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(sourceKind == kind ? HuePalette.amber : StagePalette.muted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StagePalette.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(StagePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if sourceKind == kind {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(HuePalette.amber)
                }
            }
            .padding(14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isSwitching ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
    }

    private func select(_ kind: AudioAnalysisSourceKind) {
        guard kind != sourceKind, !isSwitching else { return }
        isSwitching = true
        Task {
            // Leaving Spotify ends the experiment session: the analysis gate
            // closes first, then the receiver stops advertising.
            if kind == .microphone { receiver.stop() }
            await AudioAnalysisEngine.shared.selectSource(kind)
            sourceKind = AudioAnalysisEngine.shared.sourceKind
            isSwitching = false
        }
    }

    // MARK: Receiver

    private var receiverBlock: some View {
        let s = receiver.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(phaseColor(s.phase)).frame(width: 9, height: 9)
                Text(phaseText(s))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StagePalette.ink)
                Spacer()
                Button(receiver.isEnabled ? "Stop" : "Start") {
                    receiver.isEnabled ? receiver.stop() : receiver.start()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(receiver.isEnabled ? StagePalette.ink : .black)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(receiver.isEnabled ? StagePalette.raised : HuePalette.amber))
                .buttonStyle(.plain)
                .accessibilityLabel(receiver.isEnabled ? "Stop Spotify receiver" : "Start Spotify receiver")
            }

            if s.phase == .connected {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title.isEmpty ? playbackText(s.playback) : s.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StagePalette.ink)
                        .lineLimit(1)
                    Text(trackSubtitle(s))
                        .font(.system(size: 11))
                        .foregroundStyle(StagePalette.muted)
                        .lineLimit(1)
                }
            }

            pcmRow(s)
            analysisBars
            analyzerHint(s)

            if !s.message.isEmpty {
                Text(s.message)
                    .font(.system(size: 11))
                    .foregroundStyle(s.phase == .failed ? Color(hex: "#FF6B6B") : StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(diagnosticsLine(s))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StagePalette.muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            Text("Local experiment. Needs Spotify Premium. Audio is analyzed in memory and never saved; nothing plays out of this phone yet.")
                .font(.system(size: 10))
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private func pcmRow(_ s: SpotifyConnectReceiver.Snapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.pcmFlowing ? "waveform" : "waveform.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(s.pcmFlowing ? HuePalette.amber : StagePalette.muted)
            Text(s.pcmFlowing
                 ? "PCM \(formatRate(s.sampleRate)) · \(s.channels) ch → mono analysis"
                 : "No PCM signal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StagePalette.ink)
            Spacer()
            meter(value: s.pcmFlowing ? Double(s.peak) : 0, width: 70)
        }
        .accessibilityElement(children: .combine)
    }

    private var analysisBars: some View {
        let f = receiver.levels
        return HStack(spacing: 10) {
            bar("All", f.level)
            bar("Bass", f.bass)
            bar("Mid", f.mid)
            bar("High", f.treble)
        }
    }

    private func bar(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StagePalette.muted)
            meter(value: Double(value), width: nil)
        }
        .frame(maxWidth: .infinity)
    }

    private func meter(value: Double, width: CGFloat?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StagePalette.raised)
                Capsule().fill(HuePalette.amber)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(width: width, height: 6)
    }

    private func analyzerHint(_ s: SpotifyConnectReceiver.Snapshot) -> some View {
        let text: String
        if !s.analyzerOnSpotify {
            text = "Analyzer is still on the microphone."
        } else if s.analyzerRunning {
            text = "A Live look is listening — your lights follow this stream."
        } else {
            text = "Start a Live look in Studio to send this to your lights."
        }
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(StagePalette.muted)
    }

    // MARK: Copy

    private func phaseText(_ s: SpotifyConnectReceiver.Snapshot) -> String {
        switch s.phase {
        case .stopped: "Receiver stopped"
        case .starting: "Starting…"
        case .waiting: "Waiting for Spotify"
        case .connecting: "Connecting…"
        case .connected: s.playback == .idle ? "Connected" : "Connected · \(playbackText(s.playback))"
        case .failed: "Error"
        }
    }

    private func playbackText(_ p: SpotifyConnectReceiver.Playback) -> String {
        switch p {
        case .idle: "Nothing playing"
        case .loading: "Loading"
        case .playing: "Playing"
        case .paused: "Paused"
        }
    }

    private func trackSubtitle(_ s: SpotifyConnectReceiver.Snapshot) -> String {
        var parts: [String] = []
        if !s.artist.isEmpty { parts.append(s.artist) }
        if !s.remoteClient.isEmpty { parts.append("from \(s.remoteClient)") }
        if !s.title.isEmpty { parts.append(playbackText(s.playback)) }
        return parts.joined(separator: " · ")
    }

    private func phaseColor(_ phase: SpotifyConnectReceiver.Phase) -> Color {
        switch phase {
        case .stopped: StagePalette.muted
        case .starting, .connecting: HuePalette.amberDeep
        case .waiting: HuePalette.amber
        case .connected: Color(hex: "#4CD964")
        case .failed: Color(hex: "#FF6B6B")
        }
    }

    private func formatRate(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    private func diagnosticsLine(_ s: SpotifyConnectReceiver.Snapshot) -> String {
        var parts = [String(receiver.librespotRevision.prefix(21))]   // "librespot dev@939dc5e"
        if s.zeroconfPort > 0 { parts.append("port \(s.zeroconfPort)") }
        parts.append("frames \(s.framesDelivered)")
        parts.append("hops \(s.hopsAnalyzed)")
        if s.chunksDropped > 0 { parts.append("dropped \(s.chunksDropped)") }
        if s.firstPCMMilliseconds > 0 { parts.append("play→PCM \(s.firstPCMMilliseconds) ms") }
        parts.append("vol \(s.volumePercent)%")
        return parts.joined(separator: " · ")
    }
}

#endif
