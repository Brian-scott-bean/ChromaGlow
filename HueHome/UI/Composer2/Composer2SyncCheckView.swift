// Composer2SyncCheckView.swift
// ChromaGlow — Composer 2 (Play Along, chunk 2 item 3: Sync Check)
//
// Point the camera at a light, tap Start: the live look steps aside, the room
// blinks slowly for about 20 seconds, and the camera times how long the
// lights take to respond. The result becomes this bridge's render lead, so
// Play Along lands every beat when it is heard. The core is
// Core/Audio/SyncCheck.swift; this file runs it and shows it.

import AVFoundation
import MediaAccessibility
import QuartzCore
import SwiftUI

// MARK: - Run

@MainActor
@Observable
final class Composer2SyncCheck {
    enum Phase: Equatable {
        case preparing
        case noCamera
        case cameraOff
        /// Nothing streams to this bridge's lights for the check to borrow.
        case notStreaming
        case ready
        /// Lights bright while the camera settles on them.
        case settling
        case blinking(sent: Int, of: Int)
        case analyzing
        case measured(ms: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .preparing
    let bridgeID: String

    @ObservationIgnored let camera = SyncCheckCamera()
    @ObservationIgnored private let center: Composer2PlaybackCenter
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var cameraRunning = false
    @ObservationIgnored var now: () -> Double = { CACurrentMediaTime() }

    init(bridgeID: String, center: Composer2PlaybackCenter = .shared) {
        self.bridgeID = bridgeID
        self.center = center
    }

    var isRunning: Bool {
        switch phase {
        case .settling, .blinking, .analyzing: return true
        default: return false
        }
    }

    /// Camera permission and start; the preview is live once this returns `.ready`.
    func prepare() async {
        guard SyncCheckCamera.hasCamera else { phase = .noCamera; return }
        guard center.canSyncCheck(bridgeID: bridgeID) else { phase = .notStreaming; return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { phase = .cameraOff; return }
        do {
            try await camera.start()
            cameraRunning = true
            phase = .ready
        } catch {
            phase = .failed(Composer2SyncCheckCopy.cameraFailed)
        }
    }

    func begin() {
        guard cameraRunning, !isRunning else { return }
        let plan = SyncCheckPlan(seed: UInt64(truncatingIfNeeded: Int64(now() * 1000)),
                                 dimFlashing: MADimFlashingLightsEnabled())
        let pattern = SyncCheckPattern(plan: plan)
        guard center.beginSyncCheck(pattern) else { phase = .notStreaming; return }
        phase = .settling
        run = Task { [weak self] in await self?.drive(pattern) }
    }

    /// After a failure: start the camera again if that is what failed,
    /// otherwise run the check again.
    func retry() async {
        if cameraRunning { begin() } else { await prepare() }
    }

    /// Stops a check in progress; the look comes straight back.
    func cancel() {
        run?.cancel()
        run = nil
        center.endSyncCheck()
        _ = camera.endRecording()
        if isRunning { phase = cameraRunning ? .ready : .preparing }
    }

    func close() {
        cancel()
        if cameraRunning { camera.stop() }
        cameraRunning = false
    }

    private func drive(_ pattern: SyncCheckPattern) async {
        let plan = pattern.plan
        defer { center.endSyncCheck() }
        await camera.resumeAutoExposure()

        // The stream picks the pattern up on its next frame.
        let asked = now()
        while pattern.startedAt == nil {
            guard await pause(), now() - asked < 3 else {
                if !Task.isCancelled { phase = .failed(Composer2SyncCheckCopy.noResponse) }
                return
            }
        }
        let start = pattern.startedAt ?? asked

        // Exposure settles on the lit room, then locks just before the blinks.
        while now() < start + plan.settle - 0.15 {
            guard await pause(), stillPlaying(pattern) else { return }
        }
        await camera.lockExposure()
        camera.beginRecording()

        while !pattern.isFinished(at: now()) {
            guard await pause(), stillPlaying(pattern) else {
                _ = camera.endRecording()
                return
            }
            phase = .blinking(sent: pattern.blinksSent, of: plan.onsets.count)
        }
        let samples = camera.endRecording()
        center.endSyncCheck()

        phase = .analyzing
        let sent = pattern.sentAt
        let onDuration = plan.onDuration
        let result = await Task.detached(priority: .userInitiated) {
            SyncCheckAnalyzer.measure(samples: samples, sentAt: sent, onDuration: onDuration)
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let measurement):
            OutputLatencyModel.setMeasuredLatency(measurement.latency, bridgeID: bridgeID)
            phase = .measured(ms: Int((measurement.latency * 1000).rounded()))
        case .failure(let failure):
            phase = .failed(Composer2SyncCheckCopy.message(for: failure))
        }
    }

    /// One 50 ms step; false once the run is cancelled.
    private func pause() async -> Bool {
        try? await Task.sleep(for: .milliseconds(50))
        return !Task.isCancelled
    }

    /// The stream still asks the pattern for frames. A pattern nobody renders
    /// was replaced — a new look, a stop, a lost stream.
    private func stillPlaying(_ pattern: SyncCheckPattern) -> Bool {
        if now() - pattern.lastRenderAt < 0.5 { return true }
        phase = .failed(Composer2SyncCheckCopy.interrupted)
        return false
    }
}

// MARK: - Copy

enum Composer2SyncCheckCopy {
    static let title = "Sync Check"
    static let intro = "Point your camera at one of the lights in this room and tap Start. The lights blink about once a second for about 20 seconds while ChromaGlow times exactly how long they take to respond."
    static let privacy = "The camera only times the blinks. Nothing is recorded or leaves your phone."
    static let gentler = "Dim Flashing Lights is on, so the blinks are gentler."
    static let settling = "Hold steady while the camera adjusts to your lights."
    static let analyzing = "Working it out…"
    static let cameraFailed = "The camera couldn't start. Close any other app using the camera and try again."
    static let noResponse = "The lights didn't respond. Make sure a look is playing in this room, then try again."
    static let interrupted = "The look changed or stopped during the check. Start it again, then retry."

    static func blinking(_ sent: Int, of total: Int) -> String {
        "Keep the light in view — blink \(min(sent, total)) of \(total)"
    }

    static func measuredTitle(_ ms: Int) -> String { "Your lights respond in \(ms) ms" }
    static func measuredBody(_ ms: Int) -> String {
        "Play Along now draws every beat \(ms) ms ahead, so the lights land when you hear it."
    }

    static func message(for failure: SyncCheckAnalyzer.Failure) -> String {
        switch failure {
        case .lightNotSeen:
            return "Couldn't see the lights blink. Point the camera at a bulb or a lit lampshade, not a dark wall, and try again."
        case .tooFewBlinks(let seen, let sent):
            return "Only caught \(seen) of \(sent) blinks. Keep the light in view and hold the phone still, then try again."
        case .inconsistent:
            return "The timings didn't agree. Rest the phone on something steady and try again."
        }
    }
}

// MARK: - Screen

struct Composer2SyncCheckView: View {
    @State private var check: Composer2SyncCheck
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(bridgeID: String) {
        _check = State(initialValue: Composer2SyncCheck(bridgeID: bridgeID))
    }

    var body: some View {
        NavigationStack {
            content
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(LuminousPalette.night.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(Composer2SyncCheckCopy.title.uppercased())
                            .font(LuminousType.eyebrow)
                            .tracking(1.4)
                            .foregroundStyle(LuminousPalette.ink.opacity(0.85))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isMeasured ? "Done" : "Cancel") { dismiss() }
                            .fontWeight(.semibold)
                            .foregroundStyle(LuminousPalette.cyan)
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await check.prepare() }
        .onDisappear { check.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { check.cancel() }
        }
    }

    private var isMeasured: Bool {
        if case .measured = check.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch check.phase {
        case .noCamera:
            LuminousEmptyState(symbol: "camera.fill",
                               title: "This device has no camera to measure with.",
                               message: "Use the Light timing slider instead: slide toward earlier if the lights trail the music.")
        case .cameraOff:
            LuminousEmptyState(symbol: "camera.fill",
                               title: "Camera access is off.",
                               message: "Sync Check uses the camera to watch your lights blink. Turn it on in Settings, then come back.",
                               actionTitle: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .notStreaming:
            LuminousEmptyState(symbol: "light.beacon.max",
                               title: "Play a look in this room first.",
                               message: "Sync Check times your lights while a look streams to them. Start any look in this room, then come back.")
        default:
            measuring
        }
    }

    private var measuring: some View {
        VStack(alignment: .leading, spacing: 18) {
            SyncCheckPreview(session: check.camera.session)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .overlay { Image(systemName: "viewfinder").font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.55)) }
                .overlay { if check.phase == .preparing { ProgressView().tint(LuminousPalette.ink) } }
                .accessibilityLabel("Camera view")

            status

            Spacer(minLength: 0)
            buttons
        }
    }

    @ViewBuilder
    private var status: some View {
        switch check.phase {
        case .measured(let ms):
            VStack(alignment: .leading, spacing: 6) {
                Text(Composer2SyncCheckCopy.measuredTitle(ms))
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(LuminousPalette.ink)
                Text(Composer2SyncCheckCopy.measuredBody(ms))
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
        case .settling:
            progressLine(Composer2SyncCheckCopy.settling, fraction: 0)
        case .blinking(let sent, let total):
            progressLine(Composer2SyncCheckCopy.blinking(sent, of: total),
                         fraction: total > 0 ? Double(sent) / Double(total) : 0)
        case .analyzing:
            progressLine(Composer2SyncCheckCopy.analyzing, fraction: 1)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(Composer2SyncCheckCopy.intro)
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.ink)
                if MADimFlashingLightsEnabled() {
                    Text(Composer2SyncCheckCopy.gentler)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }
                Label(Composer2SyncCheckCopy.privacy, systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
        }
    }

    private func progressLine(_ text: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
                .contentTransition(.numericText())
            ProgressView(value: fraction)
                .tint(LuminousPalette.cyan)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var buttons: some View {
        switch check.phase {
        case .ready:
            LuminousPrimaryButton(title: "Start", symbol: "timer") {
                HapticManager.shared.medium()
                check.begin()
            }
        case .failed:
            LuminousPrimaryButton(title: "Try again", symbol: "arrow.clockwise") {
                HapticManager.shared.medium()
                Task { await check.retry() }
            }
        case .measured:
            LuminousPrimaryButton(title: "Done", symbol: "checkmark") { dismiss() }
            LuminousSecondaryButton(title: "Measure again") { check.begin() }
        case .settling, .blinking, .analyzing:
            LuminousSecondaryButton(title: "Stop") { check.cancel() }
        default:
            EmptyView()
        }
    }
}

/// The camera's live picture, so the light can be aimed at.
private struct SyncCheckPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
