// Composer2PlayAlongControls.swift
// ChromaGlow — Composer 2 (Play Along P3/P4)
//
// The one button that makes any look play along with the music, the sheet
// behind its long-press (Feel, Hits, On the One, Song colors, Light timing,
// Sync Check, Tap the one) and the beat readout that shows what the room is hearing. The
// settings are app-wide: Play Along stays on for the next look and the next
// session until it is turned off.

import AVFoundation
import QuartzCore
import SwiftUI

// MARK: - Settings

@MainActor
@Observable
final class Composer2PlayAlongSettings {
    static let shared = Composer2PlayAlongSettings()

    static let enabledKey = "playAlong.enabled"
    static let feelKey = "playAlong.feel"
    static let hitsKey = "playAlong.hits"
    static let onTheOneKey = "playAlong.onTheOne"
    static let songColorsKey = "playAlong.songColors"
    static let consentKey = "playAlong.consentShown"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    var isOn: Bool {
        didSet { defaults.set(isOn, forKey: Self.enabledKey); onChange?() }
    }
    var feel: Composer2PlayAlong.Feel {
        didSet { defaults.set(feel.rawValue, forKey: Self.feelKey); onChange?() }
    }
    /// Where the punches land: rolling across the room (the default), light
    /// to light, or the whole room at once.
    var hits: Composer2AudioModulation.Travel {
        didSet { defaults.set(hits.rawValue, forKey: Self.hitsKey); onChange?() }
    }
    /// Look changes land on the next bar line while the music plays.
    var onTheOne: Bool {
        didSet { defaults.set(onTheOne, forKey: Self.onTheOneKey); onChange?() }
    }
    /// The song's album art paints the look (needs a music source).
    var songColors: Bool {
        didSet { defaults.set(songColors, forKey: Self.songColorsKey); onChange?() }
    }

    var consentShown: Bool {
        get { defaults.bool(forKey: Self.consentKey) }
        set { defaults.set(newValue, forKey: Self.consentKey) }
    }

    /// Turning Play Along on for the first time explains listening before
    /// the system's microphone prompt.
    var needsConsentBeforeListening: Bool {
        !consentShown && AVAudioApplication.shared.recordPermission == .undetermined
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.enabledKey)
        feel = defaults.string(forKey: Self.feelKey).flatMap(Composer2PlayAlong.Feel.init(rawValue:)) ?? .groove
        hits = defaults.string(forKey: Self.hitsKey).flatMap(Composer2AudioModulation.Travel.init(rawValue:)) ?? .roll
        onTheOne = defaults.object(forKey: Self.onTheOneKey) as? Bool ?? true
        songColors = defaults.object(forKey: Self.songColorsKey) as? Bool ?? true
    }
}

// MARK: - What the room hears

/// A readable summary of the shared clock for the controls.
enum Composer2BeatReadout {
    case off
    case listening
    /// `remembered`: the grid came from the song memory (this song, these
    /// speakers, learned before).
    case locked(bpm: Int, beatInBar: Int, beatsPerBar: Int, knowsTheOne: Bool, remembered: Bool)

    @MainActor
    static func current(at now: Double = CACurrentMediaTime(), isOn: Bool) -> Composer2BeatReadout {
        guard isOn else { return .off }
        let beat = BeatClock.snapshot()
        guard Composer2PlayAlongDirector.usable(beat, at: now) else { return .listening }
        let index = beat.beatIndex(at: now)
        let perBar = max(1, beat.beatsPerBar)
        return .locked(bpm: Int(beat.bpm.rounded()), beatInBar: ((index % perBar) + perBar) % perBar,
                       beatsPerBar: perBar, knowsTheOne: beat.barConfidence >= Composer2Quantizer.barConfidenceForBar,
                       remembered: MusicSessionCoordinator.shared.beatRemembered)
    }

    var text: String {
        switch self {
        case .off: return "Play Along"
        case .listening: return "Listening…"
        case .locked(let bpm, _, _, _, let remembered): return remembered ? "\(bpm) BPM · Remembered" : "\(bpm) BPM"
        }
    }
}

// MARK: - Button

/// Tap: Play Along on or off. Long-press: its settings.
struct Composer2PlayAlongButton: View {
    var bridgeID: String? = nil

    @State private var showSheet = false
    @State private var showConsent = false
    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: Composer2PlayAlongSettings { Composer2PlayAlongSettings.shared }

    var body: some View {
        Button(action: toggle) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                label(Composer2BeatReadout.current(isOn: settings.isOn && isTabActive))
            }
        }
        .buttonStyle(LuminousPressStyle(scale: 0.97))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            HapticManager.shared.medium()
            showSheet = true
        })
        .sheet(isPresented: $showSheet) {
            Composer2PlayAlongSheet(bridgeID: bridgeID)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showConsent) {
            Composer2PlayAlongConsent {
                settings.consentShown = true
                showConsent = false
                settings.isOn = true
            }
            .presentationDetents([.medium])
        }
        .accessibilityLabel("Play Along")
        .accessibilityValue(settings.isOn ? "On" : "Off")
        .accessibilityHint("Makes the look move with the music. Touch and hold for settings.")
        .accessibilityAddTraits(settings.isOn ? [.isButton, .isSelected] : [.isButton])
    }

    private func toggle() {
        HapticManager.shared.selection()
        if !settings.isOn, settings.needsConsentBeforeListening {
            showConsent = true
            return
        }
        settings.isOn.toggle()
    }

    private func label(_ readout: Composer2BeatReadout) -> some View {
        let on = settings.isOn
        return HStack(spacing: 10) {
            Image(systemName: on ? "music.note.house.fill" : "music.note")
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Play Along")
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                if on {
                    Text(readout.text)
                        .font(.caption.weight(.semibold))
                        .opacity(0.8)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 6)
            if case .locked(_, let beatInBar, let perBar, let knowsTheOne, _) = readout {
                Composer2BeatDots(beatInBar: beatInBar, beatsPerBar: perBar, knowsTheOne: knowsTheOne)
            } else if on {
                ProgressView().controlSize(.small).tint(LuminousPalette.void)
            }
        }
        .foregroundStyle(on ? LuminousPalette.void : LuminousPalette.ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(on ? AnyShapeStyle(LuminousPalette.signalGradientHorizontal) : AnyShapeStyle(Color.white.opacity(0.07))))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(on ? 0.35 : 0.12), lineWidth: 1))
        .shadow(color: on ? LuminousPalette.cyan.opacity(0.4) : .clear, radius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Four dots for a bar of 4/4: the beat the room is on lights up; beat one
/// is drawn larger once the clock knows where bars start.
struct Composer2BeatDots: View {
    let beatInBar: Int
    let beatsPerBar: Int
    let knowsTheOne: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<min(8, max(1, beatsPerBar)), id: \.self) { i in
                Circle()
                    .fill(i == beatInBar ? LuminousPalette.void : LuminousPalette.void.opacity(0.25))
                    .frame(width: i == 0 && knowsTheOne ? 9 : 6, height: i == 0 && knowsTheOne ? 9 : 6)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sheet

struct Composer2PlayAlongSheet: View {
    var bridgeID: String?

    @State private var lightTimingMs: Double = 0
    @State private var measuredMs: Int?
    @State private var showSyncCheck = false
    @State private var showHeights = false
    @State private var tapped = false
    @Environment(\.dismiss) private var dismiss

    private var settings: Composer2PlayAlongSettings { Composer2PlayAlongSettings.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play Along")
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(LuminousPalette.ink)
                    Text("Any look moves with the music in the room — in time, on the beat, landing on the one.")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }

                Toggle(isOn: Binding(get: { settings.isOn }, set: { settings.isOn = $0 })) {
                    Text("Play Along").font(.headline).foregroundStyle(LuminousPalette.ink)
                }
                .tint(LuminousPalette.cyan)

                VStack(alignment: .leading, spacing: 10) {
                    LuminousEyebrow(text: "Feel")
                    LuminousSegmented(options: Composer2PlayAlong.Feel.allCases,
                                      selection: Binding(get: { settings.feel }, set: { settings.feel = $0 }),
                                      title: { $0.title },
                                      accessibilityLabel: "Feel")
                    Text(settings.feel.subtitle)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    LuminousEyebrow(text: "Hits")
                    LuminousSegmented(options: Composer2AudioModulation.Travel.allCases,
                                      selection: Binding(get: { settings.hits }, set: { settings.hits = $0 }),
                                      title: { $0.title },
                                      accessibilityLabel: "Hits")
                    Text(settings.feel == .glide
                         ? "Glide adds no hits of its own. Choose Groove or Hit to see them move."
                         : settings.hits.subtitle)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }

                Button {
                    HapticManager.shared.selection()
                    showHeights = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(LuminousPalette.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Light heights").font(.headline).foregroundStyle(LuminousPalette.ink)
                            Text("Which lights are low, middle and high")
                                .font(.footnote).foregroundStyle(LuminousPalette.inkSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                    .luminousGlass(radius: 18, accent: LuminousPalette.cyan, selected: false)
                }
                .buttonStyle(LuminousPressStyle(scale: 0.97))
                .sheet(isPresented: $showHeights) {
                    Composer2LightHeightsView()
                        .presentationDetents([.medium, .large])
                }

                Toggle(isOn: Binding(get: { settings.onTheOne }, set: { settings.onTheOne = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On the One").font(.headline).foregroundStyle(LuminousPalette.ink)
                        Text("Switching looks waits for the next bar")
                            .font(.footnote).foregroundStyle(LuminousPalette.inkSecondary)
                    }
                }
                .tint(LuminousPalette.cyan)

                Toggle(isOn: Binding(get: { settings.songColors }, set: { settings.songColors = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Song colors").font(.headline).foregroundStyle(LuminousPalette.ink)
                        Text("Every song paints the room with its album art")
                            .font(.footnote).foregroundStyle(LuminousPalette.inkSecondary)
                    }
                }
                .tint(LuminousPalette.cyan)

                VStack(alignment: .leading, spacing: 10) {
                    LuminousEyebrow(text: "Tap the one")
                    Button {
                        HapticManager.shared.medium()
                        BeatClock.shared.markDownbeat(near: CACurrentMediaTime())
                        tapped = true
                    } label: {
                        Text(tapped ? "Got it — tap again to move it" : "Tap when a bar starts")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(LuminousPalette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 64)
                            .luminousGlass(radius: 18, accent: LuminousPalette.violet, selected: tapped)
                    }
                    .buttonStyle(LuminousPressStyle(scale: 0.97))
                    Text("If the lights change on the wrong beat, tap on the first beat of a bar.")
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }

                if let bridgeID {
                    VStack(alignment: .leading, spacing: 6) {
                        LuminousGlowSlider(title: "Light timing", symbol: "timer",
                                           value: $lightTimingMs,
                                           range: OutputLatencyModel.userOffsetRange.lowerBound * 1000
                                               ... OutputLatencyModel.userOffsetRange.upperBound * 1000,
                                           format: { ms in
                                               let v = Int(ms.rounded())
                                               return v == 0 ? "On time" : (v < 0 ? "\(-v) ms earlier" : "\(v) ms later")
                                           },
                                           onEditingChanged: { editing in
                                               if !editing {
                                                   OutputLatencyModel.setUserOffset(lightTimingMs / 1000, bridgeID: bridgeID)
                                               }
                                           })
                        Text(measuredMs.map { "Sync Check timed your lights at \($0) ms. If they still trail the music, slide toward earlier." }
                             ?? "If the lights trail the music, slide toward earlier.")
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)

                        Button {
                            HapticManager.shared.selection()
                            showSyncCheck = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "camera.metering.center.weighted")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(LuminousPalette.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sync Check").font(.headline).foregroundStyle(LuminousPalette.ink)
                                    Text(measuredMs == nil ? "Time your lights exactly with the camera"
                                                           : "Measure again with the camera")
                                        .font(.footnote).foregroundStyle(LuminousPalette.inkSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(LuminousPalette.inkSecondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 60)
                            .luminousGlass(radius: 18, accent: LuminousPalette.cyan, selected: false)
                        }
                        .buttonStyle(LuminousPressStyle(scale: 0.97))
                        .padding(.top, 6)
                        .accessibilityHint("Uses the camera to measure how long your lights take to respond.")
                    }
                    .onAppear { refreshTiming(bridgeID) }
                    .fullScreenCover(isPresented: $showSyncCheck, onDismiss: { refreshTiming(bridgeID) }) {
                        Composer2SyncCheckView(bridgeID: bridgeID)
                    }
                }

                Label("Play Along listens to the room to find the beat. Nothing is recorded or leaves your phone.",
                      systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
            .padding(20)
        }
        .background(LuminousPalette.night.ignoresSafeArea())
    }

    private func refreshTiming(_ bridgeID: String) {
        lightTimingMs = OutputLatencyModel.userOffset(bridgeID: bridgeID) * 1000
        measuredMs = OutputLatencyModel.measuredLatency(bridgeID: bridgeID).map { Int(($0 * 1000).rounded()) }
    }
}

// MARK: - Consent

/// Shown once, before the system microphone prompt.
struct Composer2PlayAlongConsent: View {
    let onListen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(LuminousPalette.cyan)
            Text("Play along with the music")
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .foregroundStyle(LuminousPalette.ink)
            Text("ChromaGlow listens to the room to find the beat, so your lights move in time and land on the one. Audio is analyzed on your phone and never recorded or sent anywhere.")
                .font(.subheadline)
                .foregroundStyle(LuminousPalette.inkSecondary)
            Spacer(minLength: 0)
            LuminousPrimaryButton(title: "Listen", symbol: "ear") {
                HapticManager.shared.medium()
                onListen()
            }
            LuminousSecondaryButton(title: "Not now") { dismiss() }
        }
        .padding(24)
        .background(LuminousPalette.night.ignoresSafeArea())
    }
}
