// Composer2PlaybackCenter.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Owns Composer 2's one live session: attended start through the
// orchestrator's existing composition path, stop, audition-vs-applied, the
// Dashboard's Now Playing row and its stop route, and a heartbeat that
// notices when something else took the room. Every public operation runs
// on one serial chain, so rapid taps, a room change mid-start or a dismissal
// while starting cannot interleave. Only coarse state is observable.

import Foundation
import Observation
import MediaAccessibility
import QuartzCore
import UIKit

@MainActor
@Observable
final class Composer2PlaybackCenter {
    static let shared = Composer2PlaybackCenter()

    struct Session: Equatable {
        let roomID: String
        let bridgeID: String?
        let roomName: String
        let groupedLightID: String?
        var compositionName: String
        var compositionID: UUID
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
    /// A third party holds the bridge and the user must answer the prompt.
    private(set) var takeoverPending = false

    @ObservationIgnored private(set) var document: Composer2Document?
    @ObservationIgnored private(set) var output: Composer2LiveOutput?
    @ObservationIgnored private var box: CompositionParamBox?
    @ObservationIgnored private var gateway: Composer2LiveGateway?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var retainedTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var chainTail: Task<Void, Never>?
    @ObservationIgnored private var takeoverContinuation: CheckedContinuation<Bool, Never>?
    /// Identifies the question the continuation belongs to, so a timeout can
    /// never answer a LATER question.
    @ObservationIgnored private var takeoverToken = 0
    /// An unanswered takeover question is declined after this long. The
    /// question holds the serial chain; nothing — least of all the
    /// Dashboard's Stop — may wait on it forever.
    @ObservationIgnored var takeoverTimeout: Double = 60
    @ObservationIgnored private var screensAttached = 0
    @ObservationIgnored private var lastBecameActiveAt: Double = 0
    @ObservationIgnored private var isApplicationActive = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Injectable clock for tests.
    @ObservationIgnored var now: () -> Double = { CACurrentMediaTime() }
    /// Injectable heartbeat cadence (seconds); tests drive `tickHeartbeat` directly.
    @ObservationIgnored var heartbeatInterval: Double = 0.5

    init(observeApplication: Bool = true) {
        guard observeApplication else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applicationDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applicationWillResignActive() }
        })
        observers.append(center.addObserver(forName: kMADimFlashingLightsChangedNotification as NSNotification.Name,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.output?.eventCap = Composer2LiveOutput.accessibilityEventCap() }
        })
    }

    // MARK: Derived state

    var isLive: Bool {
        guard session != nil else { return false }
        switch status {
        case .live, .reconnecting, .starting: return true
        default: return false
        }
    }

    var isBusy: Bool {
        switch status {
        case .starting, .stopping: return true
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .idle: return Composer2Copy.previewOnly
        case .starting: return takeoverPending ? Composer2Copy.takeoverWaiting : Composer2Copy.liveStarting
        case .live: return session?.playMode.statusText ?? Composer2Copy.previewOnly
        case .reconnecting: return Composer2Copy.liveReconnecting
        case .stopping: return Composer2Copy.liveStopping
        case .ended(let text), .failed(let text): return text
        }
    }

    /// True when `document` is what the lights are playing. The screen asks
    /// this — not `isLive` — before offering Stop, promoting, or treating the
    /// room as busy: a look applied from the Studio card to another room is
    /// live, but it is not this screen's.
    func isPlaying(document candidate: Composer2Document) -> Bool {
        isLive && document === candidate
    }

    /// The retained document when a composition is live on `roomID`, so the
    /// screen keeps editing what the lights are playing.
    func retainedDocument(for roomID: String?) -> Composer2Document? {
        guard let session, session.roomID == roomID else { return nil }
        return document
    }

    /// A screen is showing (auditions end when the last one goes away).
    func attachScreen() { screensAttached += 1 }
    func detachScreen() { screensAttached = max(0, screensAttached - 1) }
    var hasAttachedScreen: Bool { screensAttached > 0 }

    // MARK: Serial chain

    /// Every lifecycle operation queues behind the previous one. Rapid Live
    /// presses, a stop during a start, or a dismissal mid-start are ordered,
    /// never interleaved — and a body never waits on the chain it is on.
    private func serialized<T>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = chainTail
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await body()
        }
        chainTail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    // MARK: Start

    @discardableResult
    func start(document: Composer2Document, output: Composer2LiveOutput, gateway: Composer2LiveGateway,
               audition: Bool) async -> Status {
        await serialized { [self] in
            await startCore(document: document, output: output, gateway: gateway, audition: audition)
        }
    }

    private func startCore(document: Composer2Document, output: Composer2LiveOutput,
                           gateway: Composer2LiveGateway, audition: Bool) async -> Status {
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
        if let current = session {
            if current.roomID == room.id && current.bridgeID == room.bridgeID {
                if document === self.document {
                    if !audition { promoteToApplied() }
                } else {
                    // A DIFFERENT look for the room that is already playing
                    // (a saved look tapped on the Studio card, or a look
                    // opened in Composer 2 and sent Live): hand the running
                    // transport the new composition. Returning early here
                    // used to leave the old look playing and say nothing.
                    adopt(document: document, output: output, audition: audition)
                }
                return status
            }
            await stopCore()
        }

        status = .starting
        self.gateway = gateway
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
        // The runtime plays what the document holds NOW — the screen's
        // output may not have seen the latest edits or mood change.
        output.composition = document.composition
        output.eventCap = Composer2LiveOutput.accessibilityEventCap()

        let box = Composer2PlaybackCenter.makeBox(for: document.composition, output: output)
        self.box = box
        self.output = output
        self.document = document
        document.onEdit = { [weak self] in self?.noteEdit() }

        let outcome = await gateway.start(room: room, box: box, preferStreaming: availability.prefer,
                                          askTakeover: { [weak self] in await self?.askTakeover() ?? false })
        takeoverPending = false
        switch outcome {
        case .started(let mode):
            // The orchestrator's exact slots are the truth for labels and
            // positions from here on (Composer 2.1).
            if !box.renderSlots.isEmpty {
                let areaName: String? = {
                    if case .streaming(let name) = document.roomContext.layout.source { return name }
                    return nil
                }()
                document.roomContext.layout = Composer2SlotLayout.resolved(
                    slots: box.renderSlots, lights: lights, areaName: areaName)
            } else if mode == .roomMode {
                document.roomContext.layout = gateway.roomLayout(room: room, lights: lights)
            }
            output.layoutLightIDs = document.roomContext.layout.lightIDs
            let started = now()
            session = Session(roomID: room.id, bridgeID: room.bridgeID, roomName: room.name,
                              groupedLightID: room.groupedLightID,
                              compositionName: document.composition.name,
                              compositionID: document.composition.id,
                              playMode: mode, isAudition: audition, startedAt: started)
            lastBecameActiveAt = started
            status = .live
            gateway.publishNowPlaying(roomID: room.id, bridgeID: room.bridgeID, roomName: room.name,
                                      groupedLightID: room.groupedLightID,
                                      compositionName: document.composition.name)
            gateway.installStopHandler { [weak self] bridgeID, roomID in
                await self?.stopIfOwning(bridgeID: bridgeID, roomID: roomID) ?? false
            }
            startHeartbeat()
            // Dismissed while starting: an audition has nobody to audition for.
            if audition, !hasAttachedScreen {
                await stopCore()
                status = .idle
            } else if document.roomContext.room?.id != room.id {
                // The user picked another room while this start was in
                // flight: the screen now describes that room, so a session
                // on this one would be playing somewhere nobody is looking.
                await stopCore()
                status = .idle
            }
        case .foreignController:
            unbind(releaseSource: true)
            status = .failed(Composer2Copy.liveForeignController)
        case .declined:
            unbind(releaseSource: true)
            status = .failed(Composer2Copy.takeoverDeclined)
        case .failed(let message):
            unbind(releaseSource: true)
            status = .failed(message)
        }
        return status
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

    /// Swap the look on the session that is already live in this room. The
    /// transport, its exact slots and its Now Playing row stay; only the
    /// frame source, the document and the audition flag change. The newest
    /// request decides audition-vs-applied, exactly as a fresh start would.
    private func adopt(document new: Composer2Document, output newOutput: Composer2LiveOutput, audition: Bool) {
        guard let box, var s = session else { return }
        if let previous = self.document {
            previous.onEdit = nil
            // The running transport's layout is the truth for the new look too.
            new.roomContext.layout = previous.roomContext.layout
            new.roomContext.lights = previous.roomContext.lights
        }
        if let previousOutput = self.output, previousOutput !== newOutput {
            previousOutput.releaseLiveGeometry()
        }
        newOutput.layoutLightIDs = new.roomContext.layout.lightIDs
        newOutput.composition = new.composition
        newOutput.eventCap = Composer2LiveOutput.accessibilityEventCap()
        box.frameSource = newOutput
        self.output = newOutput
        self.document = new
        new.onEdit = { [weak self] in self?.noteEdit() }
        s.isAudition = audition
        session = s
        // The new runtime has not rendered yet; do not read that as silence.
        lastBecameActiveAt = now()
        noteEdit()
    }

    // MARK: Attended takeover

    private func askTakeover() async -> Bool {
        takeoverToken &+= 1
        let token = takeoverToken
        takeoverPending = true
        let timeout = takeoverTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
            guard let self, self.takeoverToken == token, self.takeoverContinuation != nil else { return }
            self.answerTakeover(false)
        }
        return await withCheckedContinuation { continuation in
            takeoverContinuation = continuation
        }
    }

    /// The prompt's answer. Safe to call when nothing is pending.
    func answerTakeover(_ approve: Bool) {
        takeoverPending = false
        takeoverContinuation?.resume(returning: approve)
        takeoverContinuation = nil
    }

    // MARK: Edits while live

    private func noteEdit() {
        guard let box, let output, let document else { return }
        output.composition = document.composition
        let mirrored = output.mirroredReactionSource()
        if box.reaction.source != mirrored { box.reaction.source = mirrored }
        if var s = session, s.compositionName != document.composition.name || s.compositionID != document.composition.id {
            s.compositionName = document.composition.name
            s.compositionID = document.composition.id
            session = s
            gateway?.publishNowPlaying(roomID: s.roomID, bridgeID: s.bridgeID, roomName: s.roomName,
                                       groupedLightID: s.groupedLightID, compositionName: s.compositionName)
        }
    }

    /// Flush Room-mode writes immediately after a gesture (the existing idiom).
    func noteEditBurst() {
        box?.triggerRESTBurst()
    }

    // MARK: Stop

    func stop(gateway: Composer2LiveGateway) async {
        self.gateway = gateway
        await serialized { [self] in await stopCore() }
    }

    /// The Dashboard's route: stop only when the target is OUR session AND
    /// the orchestrator is still playing our box. A look that replaced ours
    /// keeps the room and its Now Playing key; stopping "by room" used to
    /// tear the replacement down while Studio's own handler never heard.
    func stopIfOwning(bridgeID: String?, roomID: String) async -> Bool {
        // Answer "not mine" at once when nothing of ours is there — never
        // queue a stranger's Stop behind our chain (a pending takeover
        // question could hold it).
        guard owns(bridgeID: bridgeID, roomID: roomID) else { return false }
        return await serialized { [self] in
            guard owns(bridgeID: bridgeID, roomID: roomID) else { return false }
            await stopCore()
            status = .idle
            return true
        }
    }

    private func owns(bridgeID: String?, roomID: String) -> Bool {
        guard let current = session, current.roomID == roomID,
              bridgeID == nil || current.bridgeID == bridgeID else { return false }
        if let box, let gateway, !gateway.isDriving(box: box) { return false }
        return true
    }

    private func stopCore() async {
        guard let current = session else {
            if case .starting = status { status = .idle }
            return
        }
        status = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        answerTakeover(false)
        gateway?.retireNowPlaying(roomID: current.roomID, bridgeID: current.bridgeID)
        // Only a transport that still plays OUR box is ours to stop.
        let stillOurs = box.map { gateway?.isDriving(box: $0) ?? true } ?? true
        if stillOurs {
            await gateway?.stop(roomID: current.roomID, bridgeID: current.bridgeID)
        }
        unbind(releaseSource: true)
        session = nil
        gateway?.installStopHandler(nil)
        status = .idle
    }

    /// Dismissal: an audition ends; an applied session survives. The task is
    /// retained here so a disappearing view cannot cancel it.
    @discardableResult
    func endAudition(gateway: Composer2LiveGateway) -> Task<Void, Never>? {
        guard session?.isAudition == true || (status == .starting && session == nil) else { return nil }
        self.gateway = gateway
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.serialized {
                guard self.session?.isAudition == true else { return }
                await self.stopCore()
            }
        }
        retainedTasks.append(task)
        // Finished tasks are dropped when the next one is retained (a task
        // is never "cancelled", so pruning on that kept every one forever).
        let tracked = task
        Task { @MainActor [weak self] in
            await tracked.value
            self?.retainedTasks.removeAll { $0 == tracked }
        }
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

    /// `releaseSource: false` keeps the runtime bound to the box: used when
    /// the orchestrator may still be driving it (a silent-but-claimed room),
    /// so a live loop never falls back to the legacy math mid-show.
    private func unbind(releaseSource: Bool) {
        if releaseSource {
            box?.frameSource = nil
            output?.releaseLiveGeometry()
        }
        box = nil
        document?.onEdit = nil
        output = nil
        document = nil
    }

    // MARK: Application lifecycle

    private func applicationDidBecomeActive() { noteApplicationActive(true) }
    private func applicationWillResignActive() { noteApplicationActive(false) }

    /// Scene-phase input (also driven directly by tests): silence while the
    /// app is inactive is expected, and the heartbeat re-arms on return.
    func noteApplicationActive(_ active: Bool) {
        isApplicationActive = active
        if active { lastBecameActiveAt = now() }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled, let self else { return }
                if !self.tickHeartbeat() { return }
            }
        }
    }

    /// One heartbeat check. Returns false once the session has ended.
    /// Silence while the app is inactive is expected and never counted.
    @discardableResult
    func tickHeartbeat() -> Bool {
        guard var current = session, let output, let gateway else { return false }
        guard isApplicationActive else { return true }
        let driving = box.map { gateway.isDriving(box: $0) } ?? true
        let verdict = Composer2Heartbeat.verdict(
            lastLiveRenderAt: output.lastLiveRenderAt,
            startedAt: max(current.startedAt, lastBecameActiveAt),
            now: now(),
            roomStillClaimed: gateway.isRoomClaimed(roomID: current.roomID, bridgeID: current.bridgeID),
            drivingOurs: driving)
        switch verdict {
        case .alive, .reconnecting:
            if verdict == .alive, status == .reconnecting { status = .live }
            if verdict == .reconnecting { status = .reconnecting }
            // A stream that failed over to Room mode keeps playing our box;
            // say so instead of "Streaming".
            if let mode = gateway.transport(roomID: current.roomID, bridgeID: current.bridgeID),
               mode != current.playMode {
                current.playMode = mode
                session = current
            }
            return true
        case .replaced:
            // Another look plays this room now. Never stop it and never
            // retire its row (retire only removes a row that is still ours);
            // nothing renders our box any more, so it is safe to let go.
            endSession(current, text: Composer2Copy.liveEndedElsewhere)
            return false
        case .lost:
            // Nobody has claimed the room for the whole reconnect window
            // (a failover that never finished, a dead bridge). Stop by room
            // so a late re-entry of OUR look is fenced off rather than left
            // playing with no owner, then let go.
            endSession(current, text: Composer2Copy.liveEndedLost)
            let room = current
            Task { @MainActor [weak self] in
                await self?.serialized {
                    guard self?.session == nil else { return }
                    await gateway.stop(roomID: room.roomID, bridgeID: room.bridgeID)
                }
            }
            return false
        }
    }

    private func endSession(_ current: Session, text: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        gateway?.retireNowPlaying(roomID: current.roomID, bridgeID: current.bridgeID)
        gateway?.installStopHandler(nil)
        unbind(releaseSource: true)
        session = nil
        status = .ended(text)
    }
}
