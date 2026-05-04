// SyncModeEngine.swift
// CastChroma — Sync Mode Controller
//
// Owns the shared AVAudioEngine and dispatches audio buffers to the
// currently active SyncEngine. Handles mic permissions, start/stop,
// and dual-mode light output:
//   • Entertainment API (DTLS streaming @ 25fps) — when an entertainment
//     config is selected and clientkey is available
//   • REST API fallback (grouped_light @ 10fps) — when no entertainment
//     config exists or DTLS fails
//
// One audio session, one tap, many engines.
// Uses nonisolated(unsafe) stopFlag for thread-safe audio tap cancellation.

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
    nonisolated(unsafe) private var stopFlag = true

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

        // Auto-select first config if only one exists
        if allConfigs.count == 1 && selectedEntertainmentConfig == nil {
            selectedEntertainmentConfig = allConfigs.first
        }
    }

    // MARK: - Start / Stop

    func start() {
        Task { await requestAndStart() }
    }

    func stop() {
        // 1. Immediately signal the audio thread to stop processing
        stopFlag = true
        isRunning = false

        // 2. Remove tap and stop engine synchronously
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // 3. Release audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 4. Stop entertainment session if active
        if let entClient = entertainmentClient {
            Task {
                await entClient.stopSession()
                log.info("Entertainment session stopped")
            }
        }
        entertainmentClient = nil

        // 5. Reset all engine state (zeros bars, levels)
        activeEngine.reset()
        transportMode = .rest
        entertainmentError = nil

        log.info("Sync stopped")
    }

    private func requestAndStart() async {
        switch AVAudioSession.sharedInstance().recordPermission {
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

        node.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buf, _ in
            // Check thread-safe flag first — no actor hop needed
            guard let self, !self.stopFlag else { return }

            // Process buffer for visualization (updates bars, levels on MainActor)
            _ = self.activeEngine.process(buffer: buf, sampleRate: Float(fmt.sampleRate))

            // Send light commands from smoothed values on MainActor.
            // Scheduled via Task to coalesce with the smoothing dispatch from process().
            // DispatchQueue.main.async ensures we run AFTER the current RunLoop tick,
            // giving the smoothing Task from process() time to complete first.
            DispatchQueue.main.async { [weak self] in
                self?.sendLightUpdate()
            }
        }

        do {
            try eng.start()
            audioEngine = eng
            isRunning   = true
            log.info("Sync started — engine: \(self.activeEngineType.rawValue), transport: \(self.transportMode.rawValue)")
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
        // For now, use the first bridge that has a client key
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
    // Optimizations vs naive approach:
    // 1. duration: 0 — instant color change (no 80ms transition animation)
    // 2. Fire-and-forget — don't await HTTP response, prevents task pile-up
    // 3. 75ms interval (13fps) — safe for all V2 bridges, backs off on errors

    private func sendRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }

        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        let bri   = max(2.0, Double(visualizer.overallLevel) * 100.0 * masterIntensity)
        let on    = visualizer.overallLevel > 0.03
        let mirek = visualizer.computeMirek()

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }

            // Fire-and-forget: send without awaiting response.
            // This eliminates ~50-200ms of HTTP round-trip from the critical path.
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await client.setGroupedLightEffect(
                        id:         glID,
                        on:         on,
                        brightness: bri,
                        xy:         nil,
                        mirek:      mirek,
                        duration:   0   // instant — no transition animation
                    )
                    // Success: tighten interval back to optimal
                    await MainActor.run {
                        guard let self else { return }
                        if self.consecutiveErrors > 0 {
                            self.consecutiveErrors = 0
                            self.restInterval = 0.075
                        }
                    }
                } catch {
                    // Adaptive backoff: if bridge is overwhelmed, slow down
                    await MainActor.run {
                        guard let self else { return }
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
