// SyncModeEngine.swift
// CastChroma — Sync Mode Controller
//
// Owns the shared AVAudioEngine and dispatches audio buffers to the
// currently active SyncEngine. Handles mic permissions, start/stop,
// and rate-limited light output to the Hue bridge.
//
// One audio session, one tap, many engines.

import Foundation
import AVFoundation
import SwiftUI
import os

// MARK: - SyncModeEngine

@Observable
@MainActor
final class SyncModeEngine {

    // MARK: Published state
    var isRunning        = false
    var permissionDenied = false
    var activeEngineType: SyncEngineType = .visualizer

    // MARK: Engines
    let visualizer = VisualizerEngine()

    // MARK: Room selection
    var selectedRoomIDs: Set<String> = []

    // MARK: Master intensity (0.0–1.0, multiplied with engine output)
    var masterIntensity: Double = 1.0

    // MARK: Private — audio
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 2048

    // MARK: Private — rate limiting
    private var lastSent: Date = .distantPast
    private let sendInterval: TimeInterval = 0.1   // 10 fps (Hue bridge spec)

    // MARK: Dependency
    private weak var orchestrator: UnifiedOrchestrator?
    private let log = Logger(subsystem: "com.lightshade.app", category: "SyncMode")

    init(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// The currently active engine instance.
    var activeEngine: SyncEngine {
        switch activeEngineType {
        case .visualizer: return visualizer
        }
    }

    // MARK: - Start / Stop

    func start() {
        Task { await requestAndStart() }
    }

    func stop() {
        isRunning = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        activeEngine.reset()
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

        let eng  = AVAudioEngine()
        let node = eng.inputNode
        let fmt  = node.outputFormat(forBus: 0)

        node.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buf, _ in
            guard let self, self.isRunning else { return }
            // Process buffer for visualization (updates bars, levels on MainActor)
            _ = self.activeEngine.process(buffer: buf, sampleRate: Float(fmt.sampleRate))
            // Send light commands from smoothed values on MainActor
            Task { @MainActor [weak self] in
                self?.sendLightUpdate()
            }
        }

        do {
            try eng.start()
            audioEngine = eng
            isRunning   = true
            log.info("Sync started — engine: \(self.activeEngineType.rawValue)")
        } catch {
            log.error("Audio engine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine Switching

    func switchEngine(to type: SyncEngineType) {
        guard type != activeEngineType else { return }
        activeEngine.reset()
        activeEngineType = type
        HapticManager.shared.medium()
        log.info("Switched to engine: \(type.rawValue)")
    }

    // MARK: - Light Control (rate-limited)
    // Reads directly from the active engine's smoothed levels (sensitivity applied).
    // This matches the original MicModeEngine pattern.

    private func sendLightUpdate() {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= sendInterval else { return }
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }
        lastSent = now

        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }

        // Read from visualizer's smoothed, sensitivity-adjusted levels
        let bri   = max(2.0, Double(visualizer.overallLevel) * 100.0 * masterIntensity)
        let on    = visualizer.overallLevel > 0.03
        let mirek = visualizer.computeMirek()

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }

            Task {
                try? await client.setGroupedLightEffect(
                    id:         glID,
                    on:         on,
                    brightness: bri,
                    xy:         nil,
                    mirek:      mirek,
                    duration:   80
                )
            }
        }
    }
}
