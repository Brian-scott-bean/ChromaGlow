// Composer2PlaybackCenter.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Owns Composer 2's one live session: start (through the orchestrator's
// existing composition start), stop, audition-vs-applied, and a heartbeat
// that notices when something else took the room. Only coarse state is
// observable; the runtime, the legacy box and the document are runtime
// plumbing and are never written at frame rate.

import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class Composer2PlaybackCenter {
    static let shared = Composer2PlaybackCenter()

    struct Session: Equatable {
        let roomID: String
        let bridgeID: String?
        let roomName: String
        var compositionName: String
        var playMode: Composer2PlayMode
        /// Audition sessions stop when the screen is dismissed; applied ones stay.
        var isAudition: Bool
        let startedAt: Double
    }

    enum Status: Equatable {
        case idle
        case starting
        case live
        case reconnecting
        case stopping
        case ended(String)
        case failed(String)
    }

    private(set) var session: Session?
    private(set) var status: Status = .idle
    /// Several Entertainment Areas cover the room — the orchestrator played Room mode.
    private(set) var severalAreas = false

    @ObservationIgnored private(set) var document: Composer2Document?
    @ObservationIgnored private(set) var output: Composer2LiveOutput?
    @ObservationIgnored private var box: CompositionParamBox?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Injectable clock for tests.
    @ObservationIgnored var now: () -> Double = { CACurrentMediaTime() }
    /// Injectable heartbeat cadence (seconds); tests drive `tickHeartbeat` directly.
    @ObservationIgnored var heartbeatInterval: Double = 0.5

    init() {}

    var isLive: Bool {
        guard session != nil else { return false }
        switch status {
        case .live, .reconnecting, .starting: return true
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .idle: return Composer2Copy.previewOnly
        case .starting: return Composer2Copy.liveStarting
        case .live: return session?.playMode.statusText ?? Composer2Copy.previewOnly
        case .reconnecting: return Composer2Copy.liveReconnecting
        case .stopping: return Composer2Copy.liveStopping
        case .ended(let text), .failed(let text): return text
        }
    }

    /// The retained document when a composition is live on `roomID`, so the
    /// screen keeps editing what the lights are playing.
    func retainedDocument(for roomID: String?) -> Composer2Document? {
        guard let session, session.roomID == roomID else { return nil }
        return document
    }

    // MARK: Start

    @discardableResult
    func start(document: Composer2Document, output: Composer2LiveOutput, gateway: Composer2LiveGateway,
               audition: Bool) async -> Status {
        let room = document.roomContext.room
        switch gateway.gate(for: room) {
        case .demo:
            status = .failed(Composer2Copy.liveDemoUnavailable)
            return status
        case .noRoom:
            status = .failed(Composer2Copy.liveNoRoom)
            return status
        case .noBridge:
            status = .failed(Composer2Copy.liveNoBridge)
            return status
        case .ready:
            break
        }
        guard let room else {
            status = .failed(Composer2Copy.liveNoRoom)
            return status
        }
        if let current = session, current.roomID != room.id || current.bridgeID != room.bridgeID {
            await stop(gateway: gateway)
        } else if session != nil {
            // Already live on this room: promote or keep.
            if !audition { promoteToApplied() }
            return status
        }

        status = .starting
        let availability = gateway.streamAvailability(for: room)
        severalAreas = availability.severalAreas
        let lights = gateway.lightItems(room: room)
        if availability.prefer, let streaming = gateway.streamingLayout(room: room, lights: lights) {
            document.roomContext.layout = streaming
        } else {
            document.roomContext.layout = gateway.roomLayout(room: room, lights: lights)
        }
        document.roomContext.lights = lights
        output.layoutLightIDs = document.roomContext.layout.lightIDs

        let box = Composer2PlaybackCenter.makeBox(for: document.composition, output: output)
        self.box = box
        self.output = output
        self.document = document
        document.onEdit = { [weak self] in self?.noteEdit() }

        let outcome = await gateway.start(room: room, box: box, preferStreaming: availability.prefer)
        switch outcome {
        case .started(let mode):
            if mode == .roomMode, !availability.prefer || streamingFailedSilently(availability) {
                document.roomContext.layout = gateway.roomLayout(room: room, lights: lights)
                output.layoutLightIDs = document.roomContext.layout.lightIDs
            }
            session = Session(roomID: room.id, bridgeID: room.bridgeID, roomName: room.name,
                              compositionName: document.composition.name, playMode: mode,
                              isAudition: audition, startedAt: now())
            status = .live
            startHeartbeat(gateway: gateway)
        case .foreignController:
            unbind()
            status = .failed(Composer2Copy.liveForeignController)
        case .failed(let message):
            unbind()
            status = .failed(message)
        }
        return status
    }

    private func streamingFailedSilently(_ availability: Composer2StreamAvailability) -> Bool {
        availability.prefer
    }

    /// The legacy box the orchestrator drives: coherent prime colours, no
    /// legacy motion, and a reaction source that mirrors the composition's
    /// microphone need so the orchestrator holds the demand for us.
    static func makeBox(for composition: Composer2Composition, output: Composer2LiveOutput) -> CompositionParamBox {
        var palette = PaletteConfig()
        let stops = composition.primaryStops
        palette.mode = .gradient
        palette.color1 = CodableColor(x: stops[0].x, y: stops[0].y)
        palette.color2 = CodableColor(x: stops[1].x, y: stops[1].y)
        palette.color3 = nil
        var motion = MotionConfig()
        motion.pattern = .static
        motion.speed = 0
        var envelope = EnvelopeConfig()
        envelope.shape = .steady
        envelope.maxBrightness = 100
        envelope.minBrightness = 0
        var reaction = ReactionConfig()
        reaction.source = output.mirroredReactionSource()
        let box = CompositionParamBox(palette: palette, motion: motion, envelope: envelope, reaction: reaction)
        box.frameSource = output
        return box
    }

    // MARK: Edits while live

    private func noteEdit() {
        guard let box, let output, let document else { return }
        output.composition = document.composition
        let mirrored = output.mirroredReactionSource()
        if box.reaction.source != mirrored { box.reaction.source = mirrored }
        if var s = session, s.compositionName != document.composition.name {
            s.compositionName = document.composition.name
            session = s
        }
    }

    /// Flush Room-mode writes immediately after a gesture (the existing idiom).
    func noteEditBurst() {
        box?.triggerRESTBurst()
    }

    // MARK: Stop

    func stop(gateway: Composer2LiveGateway) async {
        guard let current = session else {
            unbind()
            if case .starting = status { status = .idle }
            return
        }
        status = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await gateway.stop(roomID: current.roomID, bridgeID: current.bridgeID)
        unbind()
        session = nil
        status = .idle
    }

    /// Dismissal: an audition ends; an applied session survives. The task is
    /// retained here so a disappearing view cannot cancel it.
    @discardableResult
    func endAudition(gateway: Composer2LiveGateway) -> Task<Void, Never>? {
        guard session?.isAudition == true else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.stop(gateway: gateway)
        }
        stopTask = task
        return task
    }

    func promoteToApplied() {
        guard var s = session else { return }
        s.isAudition = false
        session = s
    }

    func clearNotice() {
        switch status {
        case .ended, .failed: status = .idle
        default: break
        }
    }

    private func unbind() {
        box?.frameSource = nil
        box = nil
        output?.releaseLiveGeometry()
        document?.onEdit = nil
        output = nil
        document = nil
    }

    // MARK: Heartbeat

    private func startHeartbeat(gateway: Composer2LiveGateway) {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled, let self else { return }
                if !self.tickHeartbeat(gateway: gateway) { return }
            }
        }
    }

    /// One heartbeat check. Returns false once the session has ended.
    @discardableResult
    func tickHeartbeat(gateway: Composer2LiveGateway) -> Bool {
        guard let current = session, let output else { return false }
        let verdict = Composer2Heartbeat.verdict(
            lastLiveRenderAt: output.lastLiveRenderAt, startedAt: current.startedAt, now: now(),
            roomStillClaimed: gateway.isRoomClaimed(roomID: current.roomID))
        switch verdict {
        case .alive:
            if status == .reconnecting { status = .live }
            return true
        case .reconnecting:
            status = .reconnecting
            return true
        case .ended:
            // Someone else owns the room now — never call stop, that would
            // tear down THEIR runtime.
            heartbeatTask?.cancel()
            heartbeatTask = nil
            unbind()
            session = nil
            status = .ended(Composer2Copy.liveEndedElsewhere)
            return false
        }
    }
}
