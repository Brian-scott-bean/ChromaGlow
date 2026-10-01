// SpotifyConnectExperimentSection.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment)
//
// The experiment surface inside the Luminous Music Source sheet: choose what
// light sync analyzes (Microphone, or Spotify Connect — Experimental), run the
// receiver, choose where the music plays (this iPhone's speaker, Bluetooth or
// AirPlay — Phase 2) and nudge the light timing. Everything shown is polled
// from SpotifyConnectReceiver; the analyzer bars are AudioAnalysisEngine's own
// published bass/mid/high/overall — the values every Live look reads.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVKit
import SwiftUI

struct SpotifyConnectExperimentSection: View {
    @State private var sourceKind: AudioAnalysisSourceKind = .microphone
    @State private var isSwitching = false
    @State private var copied = false
    @State private var showsLog = false

    private var receiver: SpotifyConnectReceiver { .shared }
    private var output: SpotifyPlaybackOutput { receiver.output }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LuminousGroup(title: "Light-sync audio · Experiment") {
                sourceRow(.microphone,
                          title: "Microphone",
                          subtitle: "Listens in the room — the normal path",
                          symbol: "mic.fill")
                LuminousRowDivider()
                sourceRow(.spotifyConnect,
                          title: "Spotify Connect — Experimental",
                          subtitle: "Pick “\(SpotifyConnectReceiver.deviceName)” in Spotify — the lights read the music itself",
                          symbol: "dot.radiowaves.left.and.right")
            }

            if sourceKind == .spotifyConnect {
                receiverGroup
                soundGroup
                signalGroup
                diagnosticsGroup
            }
        }
        .onAppear { sourceKind = AudioAnalysisEngine.shared.sourceKind }
    }

    // MARK: Source selector

    private func sourceRow(_ kind: AudioAnalysisSourceKind, title: String,
                           subtitle: String, symbol: String) -> some View {
        let active = sourceKind == kind
        return Button { select(kind) } label: {
            LuminousRow(symbol: symbol,
                        tint: active ? LuminousPalette.lime : LuminousPalette.inkSecondary,
                        title: title,
                        subtitle: subtitle) {
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LuminousPalette.lime)
                        .shadow(color: LuminousPalette.lime.opacity(0.6), radius: 6)
                        .accessibilityHidden(true)
                }
            }
            .background(active ? LuminousPalette.lime.opacity(0.06) : .clear)
            .opacity(isSwitching ? 0.5 : 1)
        }
        .buttonStyle(LuminousRowButtonStyle())
        .disabled(isSwitching)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : [.isButton])
    }

    private func select(_ kind: AudioAnalysisSourceKind) {
        guard kind != sourceKind, !isSwitching else { return }
        isSwitching = true
        Task {
            // Leaving Spotify ends the experiment session: the analysis gate
            // closes first, then the music stops and the receiver stops
            // advertising — playback only ever runs while Spotify is the source.
            if kind == .microphone { receiver.stop() }
            await AudioAnalysisEngine.shared.selectSource(kind)
            sourceKind = AudioAnalysisEngine.shared.sourceKind
            isSwitching = false
        }
    }

    // MARK: Receiver

    private var receiverGroup: some View {
        let s = receiver.snapshot
        return LuminousGroup(title: "Receiver") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    LuminousStateChip(text: phaseText(s), dot: phaseColor(s.phase),
                                      glowing: s.phase == .connected)
                    Spacer(minLength: 0)
                    if receiver.isEnabled {
                        Button("Stop") { receiver.stop() }
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(LuminousPalette.ink)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .luminousGlass(radius: 14)
                            .buttonStyle(LuminousPressStyle(scale: 0.95))
                            .accessibilityLabel("Stop Spotify receiver")
                    } else {
                        LuminousPrimaryButton(title: "Start", symbol: "play.fill", compact: true) {
                            receiver.start()
                        }
                        .accessibilityLabel("Start Spotify receiver")
                    }
                }

                if s.phase == .connected {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title.isEmpty ? playbackText(s.playback) : s.title)
                            .font(LuminousType.cardTitle)
                            .foregroundStyle(LuminousPalette.ink)
                            .lineLimit(1)
                        Text(trackSubtitle(s))
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .lineLimit(1)
                    }
                }

                if s.phase == .waiting || s.phase == .connecting {
                    LuminousNotice(text: waitingHint, symbol: "hand.point.up.left.fill",
                                   tint: LuminousPalette.amber)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Identify to Spotify as")
                        .font(LuminousType.captionStrong)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                    LuminousSegmented(options: SpotifyConnectReceiver.Identity.allCases,
                                      selection: Binding(get: { receiver.identity },
                                                         set: { receiver.setIdentity($0) }),
                                      title: { $0.title },
                                      accessibilityLabel: "Receiver identity")
                }

                if !s.message.isEmpty {
                    Text(s.message)
                        .font(.footnote)
                        .foregroundStyle(s.phase == .failed ? LuminousPalette.danger : LuminousPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var waitingHint: String {
        if receiver.playsOnPhone {
            "Open Spotify (here or on another device), tap the speaker icon and pick “\(SpotifyConnectReceiver.deviceName)”. ChromaGlow keeps listening in the background while the receiver is on."
        } else {
            "Pick “\(SpotifyConnectReceiver.deviceName)” in Spotify. With playback off, come back to ChromaGlow within ~30 s — iOS pauses it in the background."
        }
    }

    // MARK: Sound (Phase 2)

    private var soundGroup: some View {
        LuminousGroup(title: "Sound", footer: soundFooter) {
            LuminousToggleRow(symbol: "speaker.wave.2.fill", tint: LuminousPalette.cyan,
                              title: "Play the music on this iPhone",
                              subtitle: "Off: lights only, nothing is heard",
                              isOn: Binding(get: { receiver.playsOnPhone },
                                            set: { receiver.setPlaysOnPhone($0) }))
            if receiver.playsOnPhone {
                LuminousRowDivider()
                LuminousRow(symbol: output.routeIsAirPlay ? "airplayaudio" : "hifispeaker.fill",
                            tint: LuminousPalette.violet,
                            title: "Playing on",
                            subtitle: routeSubtitle) {
                    SpotifyRoutePickerButton()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Choose a speaker")
                }
                if output.state == .interrupted {
                    LuminousRowDivider()
                    Button { output.resume() } label: {
                        LuminousRow(symbol: "pause.circle.fill", tint: LuminousPalette.amber,
                                    title: "Audio was interrupted",
                                    subtitle: "Tap to resume the music")
                    }
                    .buttonStyle(LuminousRowButtonStyle())
                }
                if case .failed(let reason) = output.state {
                    LuminousRowDivider()
                    LuminousRow(symbol: "exclamationmark.triangle.fill", tint: LuminousPalette.danger,
                                title: "Couldn't start the audio", subtitle: reason) { EmptyView() }
                }
            }
            LuminousRowDivider()
            LuminousGlowSlider(title: "Light timing", symbol: "timer",
                               value: Binding(get: { Double(receiver.lightOffsetMs) },
                                              set: { receiver.setLightOffset(milliseconds: Int(($0 / 10).rounded()) * 10) }),
                               range: Double(SpotifyConnectReceiver.lightOffsetRange.lowerBound)
                                   ... Double(SpotifyConnectReceiver.lightOffsetRange.upperBound),
                               colors: [LuminousPalette.violet, LuminousPalette.magenta],
                               format: offsetText,
                               accessibilityName: "Light timing")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var routeSubtitle: String {
        let name = output.routeName.isEmpty ? "This iPhone" : output.routeName
        guard output.state == .playing else { return name }
        return "\(name) · \(Int((output.routeLatency * 1000).rounded())) ms behind"
    }

    private var soundFooter: String {
        "Lights already wait for the speaker. If they still look early or late, nudge Light timing — later if the lights lead the beat, earlier if they trail it."
    }

    private func offsetText(_ ms: Double) -> String {
        let value = Int(ms.rounded())
        if value == 0 { return "In step" }
        return value > 0 ? "\(value) ms later" : "\(-value) ms earlier"
    }

    // MARK: Signal

    private var signalGroup: some View {
        let s = receiver.snapshot
        return LuminousGroup(title: "Signal") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: s.pcmFlowing ? "waveform" : "waveform.slash")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(s.pcmFlowing ? LuminousPalette.lime : LuminousPalette.inkTertiary)
                    Text(s.pcmFlowing
                         ? "PCM \(formatRate(s.sampleRate)) · \(s.channels) ch → mono analysis"
                         : "No PCM signal")
                        .font(LuminousType.captionStrong)
                        .foregroundStyle(LuminousPalette.ink)
                    Spacer(minLength: 0)
                    meter(value: s.pcmFlowing ? Double(s.peak) : 0, width: 70)
                }
                .accessibilityElement(children: .combine)

                analysisBars

                Text(analyzerHint(s))
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(LuminousPalette.inkSecondary)
            meter(value: Double(value), width: nil)
        }
        .frame(maxWidth: .infinity)
    }

    private func meter(value: Double, width: CGFloat?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [LuminousPalette.cyan, LuminousPalette.magenta],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .shadow(color: LuminousPalette.magenta.opacity(0.5), radius: 4)
            }
        }
        .frame(width: width, height: 6)
    }

    private func analyzerHint(_ s: SpotifyConnectReceiver.Snapshot) -> String {
        if !s.analyzerOnSpotify {
            "The analyzer is still on the microphone."
        } else if s.analyzerRunning {
            "A Live look is listening — your lights follow this stream."
        } else {
            "Go Live with a look that dances to music to send this to your lights."
        }
    }

    // MARK: Diagnostics

    private var diagnosticsGroup: some View {
        let s = receiver.snapshot
        return LuminousGroup(title: "Diagnostics",
                             footer: "Local experiment. Needs Spotify Premium. Audio is decoded in memory and never saved.") {
            VStack(alignment: .leading, spacing: 10) {
                Text(diagnosticsLine(s))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showsLog, !receiver.logTail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(receiver.logTail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LuminousPalette.inkSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LuminousPalette.void.opacity(0.6)))
                }

                HStack(spacing: 10) {
                    LuminousChip(title: showsLog ? "Hide log" : "Show log",
                                 symbol: "text.alignleft", selected: showsLog) { showsLog.toggle() }
                    LuminousChip(title: copied ? "Copied" : "Copy diagnostics",
                                 symbol: copied ? "checkmark" : "doc.on.doc") { copyDiagnostics() }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        }
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = receiver.diagnosticsReport()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
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
        case .stopped: LuminousPalette.inkSecondary
        case .starting, .connecting: LuminousPalette.amber
        case .waiting: LuminousPalette.cyan
        case .connected: LuminousPalette.live
        case .failed: LuminousPalette.danger
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
        if receiver.playsOnPhone {
            parts.append("queue \(s.playbackQueuedMs) ms")
            if s.underruns > 0 { parts.append("underruns \(s.underruns)") }
        }
        parts.append("lights +\(s.presentationDelayMs) ms")
        return parts.joined(separator: " · ")
    }
}

/// The system speaker picker (AirPlay, Bluetooth, this iPhone) — public AVKit.
private struct SpotifyRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(LuminousPalette.inkSecondary)
        picker.activeTintColor = UIColor(LuminousPalette.cyan)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#endif
