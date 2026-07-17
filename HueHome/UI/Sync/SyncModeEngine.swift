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

// MARK: - RestSender (latest-wins mailbox)
//
// Solves the "bridge backlog" problem inherent to REST vs Entertainment API:
//
//   Entertainment (UDP/DTLS): connectionless. Bridge applies the LATEST packet
//   immediately, dropping older unprocessed ones. Zero queue. Zero latency.
//
//   REST (HTTP/TCP): sequential. Bridge processes each PUT in order. If we
//   send faster than ~10 req/s the queue grows, lights replay stale values.
//
// Solution — mailbox pattern:
//   • Only 1 HTTP request in-flight at a time.
//   • New values overwrite the pending slot — stale intermediate values dropped.
//   • After in-flight completes, immediately sends latest pending (if any).
//   • Max bridge queue depth: 1 (in-flight) + 1 (pending). Never deeper.
//
// Result: bridge always sees the LATEST desired state, not a backlog.

actor RestSender {
    private var isInflight = false
    // @Sendable @MainActor function type: the enqueued closures are formed
    // inside @MainActor methods and already execute on the main actor today
    // (they synchronously touch main-actor state). @MainActor isolation lets
    // a @Sendable closure legally capture that non-Sendable main-actor state
    // (SE-0434), and @Sendable lets the value cross into this actor.
    // Nonisolated closures (enqueueStudioRestWrite) convert implicitly.
    private var pending: (@Sendable @MainActor () async -> Void)?

    /// Enqueue work. If something is already in-flight the closure overwrites
    /// any previous pending value (old one is silently dropped).
    func enqueue(_ work: @escaping @Sendable @MainActor () async -> Void) {
        pending = work          // always latest — overwrites stale pending
        guard !isInflight else { return }
        Task { await flush() }
    }

    private func flush() async {
        while let work = pending {
            pending    = nil
            isInflight = true
            await work()
        }
        isInflight = false
    }

    /// Drop any queued pending work (does not interrupt in-flight request).
    func clear() {
        pending = nil
    }
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

    /// Latest-wins REST sender — prevents bridge command backlog.
    private let restSender = RestSender()

    // MARK: Room selection
    var selectedRoomIDs: Set<String> = []

    // MARK: Master intensity (0.0–1.0)
    var masterIntensity: Double = 1.0

    // MARK: Private — audio
    // Capture is owned by the shared AudioAnalysisEngine (Phase 2); this
    // engine registers a raw-buffer tap and holds the .syncMode demand.
    nonisolated private static let bufferTapID = "sync-mode"

    /// Thread-safe stop flag — readable from the audio thread without actor isolation.
    @ObservationIgnored
    nonisolated(unsafe) private var stopFlag = true

    /// Audio-thread snapshot of the active engine type (L-05: the tap must
    /// not read the MainActor property; kept in sync by switchEngine()).
    @ObservationIgnored
    nonisolated(unsafe) private var tapEngineType: SyncEngineType = .visualizer

    // MARK: Private — generation counter (zombie prevention)
    /// Incremented on every stop(). In-flight Tasks compare their captured
    /// generation to the current value — if different, they bail silently.
    private var generation: Int = 0

    /// True from start() until requestAndStart() finishes. Lets stop() reach
    /// an in-flight start (permission prompt, entertainment handshake) via the
    /// generation bump — before this, stop()'s early-return guard made those
    /// windows unstoppable (L-19 class).
    private var isStarting = false

    /// Set when an audio interruption/backgrounding stopped a running sync;
    /// the matching end/foreground event auto-restarts. Any explicit stop()
    /// clears it so a user stop is never overridden by a zombie resume.
    private var resumeAfterInterruption = false

    // MARK: Private — rate limiting
    private var lastSent: Date = .distantPast
    private var restInterval: TimeInterval = 0.150
    private var consecutiveErrors = 0
    private var lastSentBri: Double = -1
    /// Tracks last-known transient state so we only send on edges (ON or OFF), not every decay tick.
    private var gamingWasTransient: Bool = false
    /// Peak follower for visualizer mode.
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

    @ObservationIgnored nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

    init(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        // NOTE (Phase 2): the .composerMicExclusiveBegan handshake is gone —
        // Sync and Composer now share the single AudioAnalysisEngine capture,
        // so there is no audio-session fight to referee.

        // Interruption/background recovery. Previously absent: a phone call,
        // Siri, or another app claiming the session silently killed sync with
        // no restart path (the tap stayed installed but no buffers arrived).
        // Pattern mirrors CompositionMicCapture, which already handled these.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal)
            else { return }
            // queue: .main guarantees this block runs on the main thread;
            // assumeIsolated keeps the call SYNCHRONOUS — a Task { @MainActor }
            // hop would defer .began handling past the audio teardown.
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self.pauseForInterruption(reason: "audio session interrupted")
                case .ended:
                    self.resumeAfterInterruptionIfNeeded(reason: "interruption ended")
                @unknown default:
                    break
                }
            }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForInterruption(reason: "app backgrounded") }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterInterruptionIfNeeded(reason: "app foregrounded") }
        })

        Task { await loadEntertainmentConfigs() }
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        AudioAnalysisEngine.removeBufferTap(id: Self.bufferTapID)
    }

    private func pauseForInterruption(reason: String) {
        guard isRunning else { return }
        stop()                          // clears resumeAfterInterruption…
        resumeAfterInterruption = true  // …so re-arm it after
        log.info("Sync paused — \(reason)")
    }

    private func resumeAfterInterruptionIfNeeded(reason: String) {
        guard resumeAfterInterruption, !isRunning else { return }
        resumeAfterInterruption = false
        log.info("Sync resuming — \(reason)")
        start()                         // full clean restart (permission, transport, tap)
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
        guard !isRunning, !isStarting else { return }
        Task { await requestAndStart() }
    }

    func stop() {
        // An explicit stop always cancels a pending interruption auto-resume,
        // even when sync is already torn down (e.g. user taps Stop while a
        // phone call has it paused). The interruption handler re-arms the flag
        // right after calling stop().
        resumeAfterInterruption = false
        guard isRunning || !stopFlag || isStarting else { return }

        // 1. Bump generation — all in-flight Tasks with old generation are zombies
        generation += 1

        // 2. Immediately signal the audio thread to stop
        stopFlag = true
        isRunning = false

        // 3. Stop display link — no more smoothing/sends
        visualizer.stopDisplayLink()
        visualizer.onUpdate = nil

        // 4. Withdraw the audio demand + buffer tap (the shared engine
        // stops itself when no consumer holds a demand)
        AudioAnalysisEngine.removeBufferTap(id: Self.bufferTapID)
        Task { await AudioAnalysisEngine.shared.setDemand(.syncMode, active: false) }

        // 5. Stop entertainment session if active
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
        gamingWasTransient = false
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
        isStarting = true
        defer { isStarting = false }
        let gen = generation
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            await startCapture(generation: gen)
        case .undetermined:
            let ok = await AVAudioApplication.requestRecordPermission()
            // L-19: bail if stop() ran while the system prompt was up —
            // otherwise this in-flight start resurrects a sync the user ended.
            guard generation == gen else { return }
            if ok { await startCapture(generation: gen) } else { permissionDenied = true }
        default:
            permissionDenied = true
        }
    }

    private func startCapture(generation gen: Int) async {
        // Try to start entertainment streaming (only if user explicitly selected one)
        await startEntertainmentIfAvailable()

        // L-19: a stop() during the (up to 10 s) entertainment handshake must
        // not be resurrected — roll back whatever the handshake just started.
        guard generation == gen else {
            if let entClient = entertainmentClient {
                entertainmentClient = nil
                transportMode = .rest
                Task { await entClient.stopSession() }
            }
            return
        }

        stopFlag = false

        // Wire display link callback: smoothing → sendLightUpdate (guaranteed order)
        visualizer.onUpdate = { [weak self] in
            self?.sendLightUpdate()
        }

        // Raw-buffer tap on the shared capture engine: always process the
        // visualizer for bar UI, plus the active engine when different.
        // (Runs on the audio thread — same contract as the old private tap.)
        tapEngineType = activeEngineType
        AudioAnalysisEngine.addBufferTap(id: Self.bufferTapID) { [weak self] buf, sampleRate in
            guard let self, !self.stopFlag else { return }
            _ = self.visualizer.process(buffer: buf, sampleRate: sampleRate)
            switch self.tapEngineType {
            case .visualizer: break   // already processed above
            case .gaming:  _ = self.gaming.process(buffer: buf, sampleRate: sampleRate)
            case .ambient: _ = self.ambient.process(buffer: buf, sampleRate: sampleRate)
            }
        }

        let captureUp = await AudioAnalysisEngine.shared.setDemand(.syncMode, active: true)
        guard generation == gen, captureUp else {
            AudioAnalysisEngine.removeBufferTap(id: Self.bufferTapID)
            stopFlag = true
            if !captureUp {
                Task { await AudioAnalysisEngine.shared.setDemand(.syncMode, active: false) }
                log.error("Shared audio capture failed to start for Sync")
            }
            return
        }

        isRunning = true
        // Start display link AFTER audio is flowing
        visualizer.startDisplayLink()
        log.info("Sync started — engine: \(self.activeEngineType.rawValue), transport: \(self.transportMode.rawValue)")
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
        tapEngineType = type   // audio-thread snapshot (L-05)
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

        let capturedGen = generation
        Task { [weak self] in
            guard let self else { return }
            // Mid-session DTLS failure: once the client's bounded reconnect
            // (M-10) is exhausted, flip to REST instead of streaming into a
            // dead socket — the next frame takes the existing REST path.
            if await entClient.isTerminallyFailed {
                guard self.generation == capturedGen else { return }
                self.entertainmentClient = nil
                self.transportMode = .rest
                self.entertainmentError = "Streaming connection lost — switched to REST"
                self.log.warning("Entertainment terminally failed — switching Sync to REST")
                return
            }
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

        let capturedRooms = rooms
        let capturedBri   = bri
        let capturedGen   = gen
        let capturedOrc   = orc
        Task { await self.restSender.enqueue { [weak self] in
            for room in capturedRooms {
                guard let glID   = room.groupedLightID,
                      let client = capturedOrc.hueClient(for: room.bridgeID) else { continue }
                do {
                    try await client.setGroupedLightEffect(
                        id:         glID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         nil,
                        mirek:      nil,
                        duration:   0
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        if self.consecutiveErrors > 0 {
                            self.consecutiveErrors = 0
                            self.restInterval = 0.150
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        self.consecutiveErrors += 1
                        if self.consecutiveErrors >= 3 {
                            // Ceiling above the 0.150 start interval or the
                            // backoff can never engage (audit L-07).
                            self.restInterval = min(0.5, self.restInterval + 0.025)
                        }
                    }
                }
            }
        } }
    }

    // MARK: REST — Gaming (edge-triggered: 2 sends per transient event)
    //
    // OLD approach: send full decay curve (100 → 60 → 36...) every 50ms.
    //   Problem: bridge processes ~10 req/s. At 50ms intervals we queue up
    //   6+ commands that replay out of sync with reality — "wildly inconsistent."
    //
    // NEW approach: only send when transient state CHANGES (ON or OFF edge).
    //   - Transient ON  → instant flash at masterIntensity × 100%, duration 0
    //   - Transient OFF → dim floor at 10%, duration 350ms (bridge interpolates)
    //   Result: 2 commands per clap. No queue. Smooth fade handled by bridge firmware.

    private func sendGamingRESTUpdate() {
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }
        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        guard !rooms.isEmpty else { return }

        let isTransient = gaming.isTransient

        // Only send on state edge: transient just started or just ended
        guard isTransient != gamingWasTransient else { return }
        gamingWasTransient = isTransient

        let bri: Double
        let duration: Int
        if isTransient {
            bri      = max(10, min(100, 100.0 * masterIntensity))
            duration = 0     // instant flash
        } else {
            bri      = max(5, gaming.ambientBrightness * masterIntensity)
            duration = 350   // smooth fade-back; bridge firmware interpolates
        }

        let gen = generation
        log.info("GAMING REST: edge=\(isTransient ? "ON" : "OFF") bri=\(bri, format: .fixed(precision: 1)) duration=\(duration)ms rooms=\(rooms.count)")

        let capturedRooms    = rooms
        let capturedBri      = bri
        let capturedDuration = duration
        let capturedGen      = gen
        let capturedOrc      = orc
        Task { await self.restSender.enqueue { [weak self] in
            for room in capturedRooms {
                guard let glID   = room.groupedLightID,
                      let client = capturedOrc.hueClient(for: room.bridgeID) else { continue }
                do {
                    try await client.setGroupedLightEffect(
                        id:         glID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         nil,
                        mirek:      nil,
                        duration:   capturedDuration
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        self.consecutiveErrors = 0
                        self.restInterval = 0.150
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        self.consecutiveErrors += 1
                    }
                }
            }
        } }
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

        let capturedRooms = rooms
        let capturedBri   = bri
        let capturedGen   = gen
        let capturedOrc   = orc
        Task { await self.restSender.enqueue { [weak self] in
            for room in capturedRooms {
                guard let glID   = room.groupedLightID,
                      let client = capturedOrc.hueClient(for: room.bridgeID) else { continue }
                do {
                    // mirek omitted: same issue as xy on gaming — grouped_light
                    // rejects mirek on rooms with non-color-temp bulbs. Brightness-only
                    // works universally. Warm/cool distinction is a future per-bulb enhancement.
                    try await client.setGroupedLightEffect(
                        id:         glID,
                        on:         true,
                        brightness: capturedBri,
                        xy:         nil,
                        mirek:      nil,
                        duration:   400
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        self.consecutiveErrors = 0
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == capturedGen else { return }
                        self.consecutiveErrors += 1
                    }
                }
            }
        } }
    }
}
