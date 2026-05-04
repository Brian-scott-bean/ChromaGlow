// SyncModeEngine.swift
// ChromaForge — Sync Mode Controller
//
// Owns the shared AVAudioEngine and dispatches audio buffers to the
// currently active SyncEngine. Handles mic permissions, start/stop,
// and dual-mode light output:
//   • Entertainment API (DTLS streaming @ 25fps) — when an entertainment
//     config is selected and clientkey is available
//   • REST API fallback (grouped_light @ 13fps) — when no entertainment
//     config exists or DTLS fails
//
// Architecture:
//   - Single engine instance per app session (created once, reused across tab switches)
//   - Generation counter prevents zombie HTTP requests after stop()
//   - stopFlag is nonisolated(unsafe) for zero-cost audio thread reads
//   - REST sends are fire-and-forget but guarded by generation ID

import Foundation
import AVFoundation
import SwiftUI
import os

// MARK: - Transport Mode

enum SyncTransportMode: String {
    case rest          = "REST"
    case entertainment = "Streaming"
}

// MARK: - SyncModeEngine

@Observable
@MainActor
final class SyncModeEngine {

    // MARK: Published state
    var isRunning        = false
    var permissionDenied = false
    var activeEngineType: SyncEngineType = .visualizer

    // MARK: Transport
    var transportMode: SyncTransportMode = .rest
    var entertainmentError: String?

    // MARK: Entertainment
    var availableEntertainmentConfigs: [EntertainmentConfig] = []
    var selectedEntertainmentConfig: EntertainmentConfig?
    private var entertainmentClient: HueEntertainmentClient?

    // MARK: Engines
    let visualizer = VisualizerEngine()

    // MARK: Room selection
    var selectedRoomIDs: Set<String> = []

    // MARK: Master intensity (0.0–1.0, multiplied with engine output)
    var masterIntensity: Double = 1.0

    // MARK: Private — audio
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 1024

    /// Thread-safe stop flag — readable from the audio thread without actor isolation.
    @ObservationIgnored
    nonisolated(unsafe) private var stopFlag = true

    // MARK: Private — generation counter (zombie request prevention)
    /// Incremented on every stop(). Fire-and-forget Tasks capture the current
    /// generation at send time — if it doesn't match when the response arrives,
    /// the result is silently discarded. This prevents zombie requests from
    /// touching engine state after stop().
    private var generation: Int = 0

    // MARK: Private — rate limiting
    private var lastSent: Date = .distantPast
    /// REST: 75ms (13fps) — safe for all V2 bridges.
    /// Entertainment: 40ms (25fps) — DTLS streaming, no bridge rate limit.
    /// Falls back to 120ms if bridge returns errors (adaptive backoff).
    private var restInterval: TimeInterval = 0.075
    private var consecutiveErrors = 0
    private var sendInterval: TimeInterval { transportMode == .entertainment ? 0.04 : restInterval }

    // MARK: Dependency
    private weak var orchestrator: UnifiedOrchestrator?
    private let log = Logger(subsystem: "com.lightshade.app", category: "SyncMode")

    init(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        Task { await loadEntertainmentConfigs() }
    }

    /// The currently active engine instance.
    var activeEngine: SyncEngine {
        switch activeEngineType {
        case .visualizer: return visualizer
        }
    }

    // MARK: - Entertainment Config Loading

    /// Fetch available entertainment configurations from all connected bridges.
    func loadEntertainmentConfigs() async {
        guard let orc = orchestrator else { return }
        let manager = EntertainmentConfigManager()
        var allConfigs: [EntertainmentConfig] = []

        for bridgeID in orc.allBridgeIDs {
            guard let client = orc.hueClient(for: bridgeID) else { continue }
            do {
                let configs = try await manager.fetchConfigs(client: client)
                allConfigs.append(contentsOf: configs)
                log.info("Found \(configs.count) entertainment config(s) on bridge \(bridgeID)")
            } catch {
                log.warning("Failed to fetch entertainment configs from \(bridgeID): \(error.localizedDescription)")
            }
        }

        availableEntertainmentConfigs = allConfigs
        // Don't auto-select — user explicitly picks entertainment area vs rooms.
        // Auto-selecting would silently route sends through DTLS instead of REST,
        // making room-based sync appear broken.
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        Task { await requestAndStart() }
    }

    func stop() {
        guard isRunning || !stopFlag else { return }

        // 1. Bump generation — all in-flight Tasks with old generation are now zombies
        generation += 1

        // 2. Immediately signal the audio thread to stop processing
        stopFlag = true
        isRunning = false

        // 3. Remove tap and stop engine synchronously
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // 4. Release audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 5. Stop entertainment session if active
        if let entClient = entertainmentClient {
            Task {
                await entClient.stopSession()
                log.info("Entertainment session stopped")
            }
        }
        entertainmentClient = nil

        // 6. Reset all engine state (zeros bars, levels)
        activeEngine.reset()
        visualizer.stopDisplayLink()    // stop polling — no more sends
        visualizer.onUpdate = nil       // disconnect callback
        transportMode = .rest
        entertainmentError = nil

        // 7. Reset rate limiting state
        consecutiveErrors = 0
        restInterval = 0.075
        lastSent = .distantPast

        log.info("Sync stopped (generation=\(self.generation))")
    }

    private func requestAndStart() async {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            await startCapture()
        case .undetermined:
            let ok = await AVAudioApplication.requestRecordPermission()
            if ok { await startCapture() } else { permissionDenied = true }
        default:
            permissionDenied = true
        }
    }

    private func startCapture() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
        } catch {
            log.error("Audio session error: \(error.localizedDescription)")
            return
        }

        // Try to start entertainment streaming mode
        await startEntertainmentIfAvailable()

        let eng  = AVAudioEngine()
        let node = eng.inputNode
        let fmt  = node.outputFormat(forBus: 0)

        // Clear the stop flag BEFORE installing the tap
        stopFlag = false

        // Wire the visualizer callback: after smoothing on MainActor,
        // immediately send light update — guaranteed fresh values.
        visualizer.onUpdate = { [weak self] in
            self?.sendLightUpdate()
        }

        node.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buf, _ in
            guard let self, !self.stopFlag else { return }
            // FFT on audio thread → writes to lock-free pendingFrame.
            // No Task created — zero MainActor queue pressure.
            _ = self.activeEngine.process(buffer: buf, sampleRate: Float(fmt.sampleRate))
        }

        do {
            try eng.start()
            audioEngine = eng
            isRunning   = true
            // Start the display link AFTER audio is flowing.
            // It polls pendingFrame at 60fps → applySmoothing → onUpdate → sendLightUpdate.
            visualizer.startDisplayLink()
            log.info("Sync started — engine: \(self.activeEngineType.rawValue), transport: \(self.transportMode.rawValue), generation=\(self.generation)")
        } catch {
            log.error("Audio engine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Entertainment Setup

    private func startEntertainmentIfAvailable() async {
        guard let config = selectedEntertainmentConfig,
              let orc = orchestrator else {
            transportMode = .rest
            log.info("No entertainment config selected — using REST fallback")
            return
        }

        // Find the bridge that has this entertainment config
        for bridgeID in orc.allBridgeIDs {
            guard let client = orc.hueClient(for: bridgeID),
                  let clientKey = KeychainManager.shared.loadClientKey(for: bridgeID) else {
                continue
            }

            do {
                let (ip, token) = try client.credentials()
                let entClient = HueEntertainmentClient(
                    bridgeIP: ip,
                    username: token,
                    clientKeyHex: clientKey,
                    restClient: client
                )

                try await entClient.startSession(configID: config.id)
                entertainmentClient = entClient
                transportMode = .entertainment
                entertainmentError = nil
                log.info("Entertainment streaming started on bridge \(bridgeID)")
                return
            } catch {
                log.warning("Entertainment start failed on \(bridgeID): \(error.localizedDescription)")
                entertainmentError = error.localizedDescription
            }
        }

        // Fallback to REST
        transportMode = .rest
        log.info("Entertainment unavailable — falling back to REST")
    }

    // MARK: - Engine Switching

    func switchEngine(to type: SyncEngineType) {
        guard type != activeEngineType else { return }
        activeEngine.reset()
        activeEngineType = type
        HapticManager.shared.medium()
        log.info("Switched to engine: \(type.rawValue)")
    }

    // MARK: - Light Control (dual-mode, rate-limited)

    private func sendLightUpdate() {
        guard isRunning, !stopFlag else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= sendInterval else { return }
        lastSent = now

        switch transportMode {
        case .entertainment:
            sendStreamingUpdate()
        case .rest:
            sendRESTUpdate()
        }
    }

    // MARK: Entertainment Streaming (25fps)

    private func sendStreamingUpdate() {
        guard let entClient = entertainmentClient,
              let config = selectedEntertainmentConfig else {
            // Lost entertainment client — fall back
            transportMode = .rest
            sendRESTUpdate()
            return
        }

        // Map visualizer levels to channel data
        let brightness = Double(visualizer.overallLevel) * masterIntensity
        let mirek = visualizer.computeMirek()

        // Convert mirek to approximate CIE xy for streaming
        // mirek 153 (6500K cold) → xy≈(0.31, 0.33)
        // mirek 500 (2000K warm) → xy≈(0.53, 0.41)
        let t = Double(mirek - 153) / Double(500 - 153)  // 0=cold, 1=warm
        let x = 0.31 + t * 0.22   // lerp x
        let y = 0.33 + t * 0.08   // lerp y

        let channelData = config.channels.map { ch in
            (id: UInt8(ch.id), x: x, y: y, brightness: brightness)
        }

        Task {
            await entClient.send(channels: channelData)
        }
    }

    // MARK: REST Fallback (13fps, fire-and-forget)
    //
    // Simple and proven:
    // 1. Rate limiter (75ms / 13fps) — prevents over-sending
    // 2. Fire-and-forget — don't await HTTP response on the critical path
    // 3. Generation counter — zombie Tasks from old sessions are discarded
    // 4. duration: 0 — instant color change (no transition animation)

    private func sendRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }

        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        let bri   = max(2.0, Double(visualizer.overallLevel) * 100.0 * masterIntensity)
        let mirek = visualizer.computeMirek()
        let sendGeneration = generation

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await client.setGroupedLightEffect(
                        id:         glID,
                        on:         true,
                        brightness: bri,
                        xy:         nil,
                        mirek:      mirek,
                        duration:   0
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == sendGeneration else { return }
                        if self.consecutiveErrors > 0 {
                            self.consecutiveErrors = 0
                            self.restInterval = 0.075
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == sendGeneration else { return }
                        self.consecutiveErrors += 1
                        if self.consecutiveErrors >= 3 {
                            self.restInterval = min(0.15, self.restInterval + 0.025)
                            self.log.info("REST backoff → \(Int(self.restInterval * 1000))ms")
                        }
                    }
                }
            }
        }
    }
}
