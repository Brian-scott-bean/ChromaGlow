// SyncModeEngine.swift
// CastChroma — Sync Mode Controller
//
// Owns the shared AVAudioEngine and dispatches audio buffers to the
// currently active SyncEngine. Handles mic permissions, start/stop,
// and dual-mode light output:
//   • Entertainment API (DTLS streaming @ 25fps) — when user explicitly
//     selects an entertainment config
//   • REST API fallback (grouped_light @ 13fps) — default for rooms/zones
//
// Architecture:
//   Audio callback → writes to VisualizerEngine's lock-free buffer
//   CADisplayLink (60fps) → reads buffer → smoothing → onUpdate → sendLightUpdate
//   No Task per buffer. Zero accumulation. Instant stop.

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
    let gaming     = GamingEngine()
    let ambient    = AmbientEngine()

    // MARK: Room selection
    var selectedRoomIDs: Set<String> = []

    // MARK: Master intensity (0.0–1.0)
    var masterIntensity: Double = 1.0

    // MARK: Private — audio
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 1024

    /// Thread-safe stop flag — readable from the audio thread without actor isolation.
    @ObservationIgnored
    nonisolated(unsafe) private var stopFlag = true

    // MARK: Private — generation counter (zombie prevention)
    /// Incremented on every stop(). In-flight Tasks compare their captured
    /// generation to the current value — if different, they bail silently.
    private var generation: Int = 0

    // MARK: Private — rate limiting
    private var lastSent: Date = .distantPast
    private var restInterval: TimeInterval = 0.150   // 150ms = 6fps per room
    private var consecutiveErrors = 0
    private var lastSentBri: Double = -1             // skip sends when bri hasn't changed meaningfully
    /// Peak follower: jumps instantly to loud levels, decays slowly back to 0.
    /// 0.80 per 150ms call ≈ 2 seconds to decay from 100→ below 5%.
    private var decayLevel: Double = 0
    /// Scale interval by room count so total bridge load stays constant.
    /// 1 room = 150ms, 2 rooms = 300ms, etc.
    private var sendInterval: TimeInterval {
        if transportMode == .entertainment { return 0.04 }
        if activeEngineType == .gaming   { return 0.05 }   // 20fps for instant flash
        if activeEngineType == .ambient  { return 0.50 }   // 2fps — slow breath changes
        let roomCount = max(1, selectedRoomIDs.count)
        return restInterval * Double(roomCount)
    }

    // MARK: Private — diagnostic throttle (~1 log/sec)
    private var _diagCounter: Int = 0

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
        case .gaming:     return gaming
        case .ambient:    return ambient
        }
    }

    // MARK: - Entertainment Config Loading

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
        // Do NOT auto-select. User must explicitly pick entertainment area vs rooms.
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        Task { await requestAndStart() }
    }

    func stop() {
        guard isRunning || !stopFlag else { return }

        // 1. Bump generation — all in-flight Tasks with old generation are zombies
        generation += 1

        // 2. Immediately signal the audio thread to stop
        stopFlag = true
        isRunning = false

        // 3. Stop display link — no more smoothing/sends
        visualizer.stopDisplayLink()
        visualizer.onUpdate = nil

        // 4. Remove tap and stop audio engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // 5. Release audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 6. Stop entertainment session if active
        if let entClient = entertainmentClient {
            Task {
                await entClient.stopSession()
                log.info("Entertainment session stopped")
            }
        }
        entertainmentClient = nil

        // 7. Reset engine state
        activeEngine.reset()
        gaming.reset()
        ambient.reset()
        visualizer.reset()
        transportMode = .rest
        entertainmentError = nil
        consecutiveErrors = 0
        restInterval = 0.150
        lastSent = .distantPast
        lastSentBri = -1
        decayLevel = 0  // reset peak follower

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

        // Try to start entertainment streaming (only if user explicitly selected one)
        await startEntertainmentIfAvailable()

        let eng  = AVAudioEngine()
        let node = eng.inputNode
        let fmt  = node.outputFormat(forBus: 0)

        stopFlag = false

        // Wire display link callback: smoothing → sendLightUpdate (guaranteed order)
        visualizer.onUpdate = { [weak self] in
            self?.sendLightUpdate()
        }

        // Audio callback: always process visualizer for bar UI,
        // plus active engine when different.
        node.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buf, _ in
            guard let self, !self.stopFlag else { return }
            _ = self.visualizer.process(buffer: buf, sampleRate: Float(fmt.sampleRate))
            if self.activeEngineType != .visualizer {
                _ = self.activeEngine.process(buffer: buf, sampleRate: Float(fmt.sampleRate))
            }
        }

        do {
            try eng.start()
            audioEngine = eng
            isRunning   = true
            // Start display link AFTER audio is flowing
            visualizer.startDisplayLink()
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

    // MARK: - Light Control (rate-limited, generation-guarded)

    private func sendLightUpdate() {
        // DIAGNOSTIC ~1/sec: log what's blocking sends
        _diagCounter += 1
        let shouldLog = _diagCounter >= 13  // ~13 calls/sec at 13fps
        if shouldLog { _diagCounter = 0 }

        guard isRunning, !stopFlag else {
            if shouldLog { log.info("SYNC GATE: blocked — isRunning=\(self.isRunning) stopFlag=\(self.stopFlag)") }
            return
        }

        // Always tick gaming engine at display-link speed for smooth UI
        if activeEngineType == .gaming { gaming.tick() }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSent)
        guard elapsed >= sendInterval else {
            if shouldLog { log.info("SYNC GATE: rate limited — elapsed=\(elapsed, format: .fixed(precision: 3))s interval=\(self.sendInterval, format: .fixed(precision: 3))s") }
            return
        }
        lastSent = now

        if shouldLog { log.info("SYNC GATE: PASS — transport=\(self.transportMode.rawValue) overallLevel=\(self.visualizer.overallLevel, format: .fixed(precision: 3))") }

        switch transportMode {
        case .entertainment:
            sendStreamingUpdate()
        case .rest:
            switch activeEngineType {
            case .visualizer: sendVisualizerRESTUpdate()
            case .gaming:     sendGamingRESTUpdate()
            case .ambient:    sendAmbientRESTUpdate()
            }
        }
    }

    // MARK: Entertainment Streaming (25fps, DTLS)

    private func sendStreamingUpdate() {
        guard let entClient = entertainmentClient,
              let config = selectedEntertainmentConfig else {
            transportMode = .rest
            sendVisualizerRESTUpdate()
            return
        }

        let brightness = Double(visualizer.overallLevel) * masterIntensity
        let mirek = visualizer.computeMirek()
        let t = Double(mirek - 153) / Double(500 - 153)
        let x = 0.31 + t * 0.22
        let y = 0.33 + t * 0.08

        let channelData = config.channels.map { ch in
            (id: UInt8(ch.id), x: x, y: y, brightness: brightness)
        }

        Task {
            await entClient.send(channels: channelData)
        }
    }

    // MARK: REST — Visualizer (13fps, fire-and-forget)
    //
    // Simple and proven:
    // 1. Rate limiter (150ms) prevents over-sending
    // 2. Fire-and-forget — no await on critical path
    // 3. Generation counter — zombie Tasks are discarded
    // 4. duration: 0 — instant, no transition animation

    private func sendVisualizerRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else {
            log.warning("SYNC REST: skip — selectedRoomIDs=\(self.selectedRoomIDs.count) orc=\(self.orchestrator != nil)")
            return
        }

        // Ignore ambient noise below 5% — prevents lights dimming on mic start.
        // Room noise typically registers as 0.01–0.04 overallLevel.
        guard visualizer.overallLevel > 0.05 else {
            log.info("SYNC REST: skip — ambient noise (\(self.visualizer.overallLevel, format: .fixed(precision: 4)))")
            return
        }

        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }

        // Peak follower with fast decay:
        // - Fast attack: instantly snap to new peak on loud sound
        // - Fast decay: 0.50x per 150ms ≈ 450ms to fall from 100% to below 5%
        // Creates a "fighting" effect: lights constantly try to go dark,
        // sound fights them back up. Very reactive, never "holds" a level.
        let rawLevel = Double(visualizer.overallLevel)
        if rawLevel > decayLevel {
            decayLevel = rawLevel
        } else {
            decayLevel = max(0, decayLevel * 0.50)
        }

        guard decayLevel > 0.05 else { return }  // below threshold, let lights rest

        let bri = min(100.0, decayLevel * 250.0 * masterIntensity)

        // Skip if brightness hasn't changed meaningfully from last send (>5%).
        guard abs(bri - lastSentBri) > 5.0 || lastSentBri < 0 else { return }
        lastSentBri = bri   // record optimistically — prevents duplicate sends even if HTTP fails
        let gen   = generation

        log.info("SYNC REST: SENDING bri=\(bri, format: .fixed(precision: 1)) rooms=\(rooms.count) selectedIDs=\(self.selectedRoomIDs) gen=\(gen)")

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }

            let capturedGlID = glID
            let capturedBri = bri

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    // Only send on + brightness. Mirek on grouped_light can fail
                    // if the group contains non-color-temperature lights.
                    try await client.setGroupedLightEffect(
                        id:         capturedGlID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         nil,
                        mirek:      nil,
                        duration:   0
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
                        if self.consecutiveErrors > 0 {
                            self.consecutiveErrors = 0
                            self.restInterval = 0.150  // reset to base (not old 75ms)
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
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

    // MARK: REST — Gaming (flash on transient, ambient between spikes)

    private func sendGamingRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }
        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        guard !rooms.isEmpty else { return }

        // Tick already called in sendLightUpdate at display-link speed
        let gen = generation
        let isTransient = gaming.isTransient
        let bri: Double
        let xy: (Double, Double)

        if isTransient {
            bri = gaming.flashBrightness * masterIntensity
            xy  = gaming.flashColor.xy
        } else {
            guard let ambXY = gaming.ambientColor.xy else { return }  // .off
            bri = gaming.ambientBrightness * masterIntensity
            xy  = ambXY
        }

        guard bri > 1.0 else { return }
        guard abs(bri - lastSentBri) > 3.0 || isTransient else { return }
        lastSentBri = bri

        log.info("GAMING REST: bri=\(bri, format: .fixed(precision: 1)) transient=\(isTransient) rooms=\(rooms.count)")

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }
            let capturedGlID = glID
            let capturedBri  = bri
            let capturedXY   = xy
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await client.setGroupedLightEffect(
                        id:         capturedGlID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         capturedXY,
                        mirek:      nil,
                        duration:   0
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.consecutiveErrors = 0
                        self.restInterval = 0.150
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.consecutiveErrors += 1
                    }
                }
            }
        }
    }

    // MARK: REST — Ambient (2fps, slow breath)

    private func sendAmbientRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }
        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        guard !rooms.isEmpty else { return }

        guard let bri = ambient.tick() else { return }
        guard bri > 0.5 else { return }

        // Skip tiny changes — only send if brightness shifted meaningfully
        guard abs(bri - lastSentBri) > 2.0 || lastSentBri < 0 else { return }
        lastSentBri = bri

        let mirek = ambient.colorMode.mirek
        let gen   = generation

        log.info("AMBIENT REST: bri=\(bri, format: .fixed(precision: 1)) mirek=\(mirek) present=\(self.ambient.presenceDetected)")

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }
            let capturedGlID  = glID
            let capturedBri   = bri
            let capturedMirek = mirek
            Task.detached(priority: .utility) { [weak self] in
                do {
                    try await client.setGroupedLightEffect(
                        id:         capturedGlID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         nil,
                        mirek:      capturedMirek,
                        duration:   400   // 400ms smooth transition between breath steps
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.consecutiveErrors = 0
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.consecutiveErrors += 1
                    }
                }
            }
        }
    }
}
