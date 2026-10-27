// Composer2LiveOutput.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The runtime that stands between the pure engine and the existing render
// loops. It conforms to `CompositionFrameSource`, so a legacy
// `CompositionParamBox` whose `frameSource` is this object streams Composer 2
// frames through the orchestrator's untouched transport, safety gate,
// failover and stop paths. It holds every piece of per-frame mutable state
// so nothing observable is written at frame rate.
//
// Thread safety (chunk 2): the Entertainment loop renders on its own
// executor, off the main actor, while the screen edits the look and reads
// the live frames on the main actor. One recursive lock guards every piece
// of state; every entry point below takes it, so an edit lands between two
// frames, never inside one.

import Foundation
import MediaAccessibility

final class Composer2LiveOutput: ConcurrentCompositionFrameSource, @unchecked Sendable {

    private let lock = NSRecursiveLock()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The composition being played. Edits land here synchronously; the next
    /// frame picks them up — no session restart, no task per slider tick.
    var composition: Composer2Composition {
        get { locked { _composition } }
        set {
            locked {
                guard newValue != _composition else { return }
                _composition = newValue
                plansDirty = true
                derivedDirty = true
                paintTargetDirty = true
            }
        }
    }
    private var _composition: Composer2Composition

    // MARK: Song colors (P6)

    /// The playing song's album-art swatches: the look wears them (nil: as
    /// authored). A change lands on the one — on the next bar line when the
    /// clock knows where bars are, crossfading over the last eighth of a bar.
    var songSwatches: ArtworkSwatches? {
        get { locked { _songSwatches } }
        set {
            locked {
                guard newValue != _songSwatches else { return }
                _songSwatches = newValue
                paintTargetDirty = true
                swatchesChanged = true
            }
        }
    }
    private var _songSwatches: ArtworkSwatches?
    /// The composition as the room wears it right now (painted or not,
    /// mid-change or not); what the plans were built for.
    private var worn: Composer2Composition?
    /// `composition` in the song's colours (nil: no swatches).
    private var paintTarget: Composer2Composition?
    private var paintTargetDirty = true
    private var swatchesChanged = false
    /// A colour change on its way: from what the room wore, landing at a
    /// shown-time.
    private var paintChange: (from: Composer2Composition, landing: Double, preroll: Double)?
    /// A change with no grid to land on fades over this long.
    static let paintFade = 1.0

    // MARK: Play Along (P3)

    /// The user wants this look to play along with the music. The room
    /// changes only once the clock has a beat — on the one (see
    /// `Composer2PlayAlongDirector`).
    var playAlongRequested: Bool {
        get { locked { _playAlongRequested } }
        set {
            locked {
                _playAlongRequested = newValue
                _director.requested = newValue
            }
        }
    }
    private var _playAlongRequested = false

    var playAlongFeel: Composer2PlayAlong.Feel {
        get { locked { _playAlongFeel } }
        set {
            locked {
                guard newValue != _playAlongFeel else { return }
                _playAlongFeel = newValue
                derivedDirty = true
            }
        }
    }
    private var _playAlongFeel: Composer2PlayAlong.Feel = .groove

    /// When the play-along look takes over and lets go.
    var director: Composer2PlayAlongDirector { locked { _director } }
    private var _director = Composer2PlayAlongDirector()
    /// The latest frame's blend: 0 = the look as authored, 1 = playing along.
    var playAlongWeight: Double { locked { _playAlongWeight } }
    private var _playAlongWeight: Double = 0
    /// The play-along look, re-derived on a tempo change or an edit.
    var derived: Composer2Composition? { locked { _derived } }
    private var _derived: Composer2Composition?
    private var derivedBPM: Double = 0
    private var derivedDirty = true
    private var derivedState = Composer2EngineState()
    private var derivedPlans: [Composer2LayerPlan] = []
    private var derivedBuffer: [Composer2Frame] = []

    /// 0…1 cap on event flashes and sound punches (Dim Flashing Lights ⇒
    /// 0.3). Applied on the wire and on screen alike. Every output starts from the system setting;
    /// the playback center and the screen follow its changes.
    var eventCap: Double {
        get { locked { _eventCap } }
        set { locked { _eventCap = newValue } }
    }
    private var _eventCap: Double = Composer2LiveOutput.accessibilityEventCap()

    /// iOS "Dim Flashing Lights" ⇒ events flash at 30 %, the same cap Studio
    /// applies to its strobes. It used to be defined and never set.
    static func accessibilityEventCap() -> Double {
        MADimFlashingLightsEnabled() ? 0.3 : 1
    }

    /// Light identities per render slot when a layout could resolve them.
    /// Ignored while the live loop's exact slots are installed: those carry
    /// the orchestrator's own identities, and a layout that could not name
    /// every light would otherwise erase them (light-id masks then fell back
    /// to the whole room).
    var layoutLightIDs: [String]? {
        get { locked { _layoutLightIDs } }
        set {
            locked {
                _layoutLightIDs = newValue
                guard !(geometryFromBox && !_liveSlots.isEmpty) else { return }
                _geometry = _geometry.withLightIDs(newValue)
                plansDirty = true
            }
        }
    }
    private var _layoutLightIDs: [String]?

    var state: Composer2EngineState { locked { _state } }
    private var _state = Composer2EngineState()
    var geometry: Composer2SlotGeometry { locked { _geometry } }
    private var _geometry = Composer2SlotGeometry.linear(count: 0)
    var lastFrames: [Composer2Frame] { locked { _lastFrames } }
    private var _lastFrames: [Composer2Frame] = []
    /// Engine time of the last render (any path).
    var lastRenderTime: Double? { locked { _lastRenderTime } }
    private var _lastRenderTime: Double?
    /// Host time when the LIVE loop last asked for a frame (0 = never).
    var lastLiveRenderAt: Double { locked { _lastLiveRenderAt } }
    private var _lastLiveRenderAt: Double = 0

    /// The exact slots the live loop is driving (Composer 2.1), empty otherwise.
    var liveSlots: [CompositionRenderSlot] { locked { _liveSlots } }
    private var _liveSlots: [CompositionRenderSlot] = []

    /// Keeps the output inside the photosensitivity budget before any gate
    /// sees it (see `Composer2FlashShaper`).
    var shaper: Composer2FlashShaper { locked { _shaper } }
    private var _shaper = Composer2FlashShaper()

    private var plans: [Composer2LayerPlan] = []
    private var plansDirty = true
    private var frameBuffer: [Composer2Frame] = []
    private var cachedRadial: [Double] = []
    private var cachedAngular: [Double] = []
    private var geometryFromBox = false

    /// A backwards jump larger than this resets the engine state.
    static let backwardsResetTolerance: Double = 0.5

    init(composition: Composer2Composition) {
        _composition = composition
    }

    func reset() {
        locked {
            _state.reset()
            _shaper.reset()
            plansDirty = true
            _lastRenderTime = nil
            _lastLiveRenderAt = 0
            _director.reset()
            derivedState.reset()
            derivedDirty = true
            _playAlongWeight = 0
            paintChange = nil
            worn = nil
            paintTargetDirty = true
        }
    }

    /// The preview's geometry (a UI layout). Ignored once a live loop has
    /// installed the orchestrator's own slot geometry.
    func setPreviewGeometry(_ g: Composer2SlotGeometry) {
        locked {
            guard !geometryFromBox else { return }
            if g != _geometry {
                _geometry = g.withLightIDs(_layoutLightIDs ?? g.lightIDs)
                plansDirty = true
            }
        }
    }

    /// Forget the live geometry (after a stop) so previews may lay out again.
    func releaseLiveGeometry() {
        locked {
            geometryFromBox = false
            cachedRadial = []
            cachedAngular = []
            _liveSlots = []
            _lastLiveRenderAt = 0
            liveHistory = []
        }
    }

    // MARK: Live frames for the screen

    /// Recent live frames with the host time the room shows each one. Live
    /// frames are rendered a lead AHEAD of now; the hero picks the one that is
    /// due, so the screen matches the sound instead of running ahead of it.
    private var liveHistory: [(at: Double, frames: [Composer2Frame])] = []
    private static let liveHistorySeconds = 1.0

    private func noteLiveFrames(_ frames: [Composer2Frame], shownAt: Double) {
        liveHistory.append((shownAt, frames))
        let oldest = shownAt - Composer2LiveOutput.liveHistorySeconds
        if let keepFrom = liveHistory.firstIndex(where: { $0.at >= oldest }), keepFrom > 0 {
            liveHistory.removeFirst(keepFrom)
        }
    }

    /// The live frames the room is showing at `hostNow` (the newest whose
    /// moment has come; the oldest kept if none has yet).
    func liveFrames(at hostNow: Double) -> [Composer2Frame] {
        locked {
            if let due = liveHistory.last(where: { $0.at <= hostNow }) { return due.frames }
            return liveHistory.first?.frames ?? _lastFrames
        }
    }

    // MARK: CompositionFrameSource

    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        renderLiveFrames(time: time, channelIDs: channelIDs, layout: CompositionLiveLayout(params: params),
                         features: features, beat: beat, hostNow: hostNow)
    }

    func renderLiveFrames(time: Double, channelIDs: [Int], layout: CompositionLiveLayout,
                          features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        locked {
            _lastLiveRenderAt = hostNow
            installGeometry(count: channelIDs.count, radial: layout.radial,
                            angular: layout.angular, slots: layout.slots)
            // Play Along P2: render the moment the room will SHOW this frame, so a
            // beat lands when it is heard rather than one bridge delay late.
            let lead = layout.outputLead.isFinite ? Composer2Math.clamp(layout.outputLead, 0, 1) : 0
            let frames = evaluateLocked(time: time + lead, features: features, beat: beat, hostNow: hostNow + lead)
            noteLiveFrames(frames, shownAt: hostNow + lead)
            guard frames.count == channelIDs.count else { return [] }
            var out: [LightFrame] = []
            out.reserveCapacity(frames.count)
            for (i, f) in frames.enumerated() {
                out.append(LightFrame(channelID: channelIDs[i], x: f.x, y: f.y, brightness: f.brightness))
            }
            return out
        }
    }

    // MARK: Evaluation

    /// Evaluate on the current geometry. Shared by the live loop and the
    /// on-screen preview so both show the same frames.
    @discardableResult
    func evaluate(time rawTime: Double, features: AudioFeatures = .silent, beat: BeatSnapshot = .none,
                  hostNow: Double = 0) -> [Composer2Frame] {
        locked { evaluateLocked(time: rawTime, features: features, beat: beat, hostNow: hostNow) }
    }

    private func evaluateLocked(time rawTime: Double, features: AudioFeatures, beat: BeatSnapshot,
                                hostNow: Double) -> [Composer2Frame] {
        var time = rawTime.isFinite ? rawTime : (_lastRenderTime ?? 0)
        if let last = _lastRenderTime, time < last - Composer2LiveOutput.backwardsResetTolerance {
            _state.reset()
            derivedState.reset()
            _shaper.reset()
            plansDirty = true
        }
        if time.isNaN { time = 0 }
        // Song colors: the look as the room wears it at this shown-time.
        let look = wornComposition(at: hostNow, beat: beat)
        if plansDirty {
            plans = Composer2Engine.plans(for: look, geometry: _geometry)
            derivedPlans = []
            plansDirty = false
        }

        // Play Along: the plain look, the play-along look, or a crossfade
        // landing on the one. `hostNow` is the moment this frame is SHOWN.
        let mix = _director.update(at: hostNow, beat: beat)
        _playAlongWeight = mix.weight
        if mix.weight < 1 {
            Composer2Engine.evaluate(look, time: time, geometry: _geometry, plans: &plans, state: &_state,
                                     audio: features, beat: beat, hostNow: hostNow, eventCap: _eventCap,
                                     into: &frameBuffer)
        }
        if mix.weight > 0 {
            if _derived == nil || derivedDirty || derivedBPM != mix.bpm {
                _derived = Composer2PlayAlong.apply(look, feel: _playAlongFeel, bpm: mix.bpm,
                                                    category: Composer2ThemeCatalog.entry(id: _composition.id)?.category)
                derivedBPM = mix.bpm
                derivedDirty = false
            }
            if let derived = _derived {
                Composer2Engine.evaluate(derived, time: time, geometry: _geometry, plans: &derivedPlans,
                                         state: &derivedState, audio: features, beat: beat, hostNow: hostNow,
                                         eventCap: _eventCap, into: &derivedBuffer)
                if mix.weight >= 1 || frameBuffer.count != derivedBuffer.count {
                    swap(&frameBuffer, &derivedBuffer)
                } else {
                    frameBuffer = Composer2FlashShaper.blend(frameBuffer, derivedBuffer, mix.weight)
                }
            }
        }
        frameBuffer = _shaper.shape(frameBuffer, at: time)
        _lastRenderTime = time
        _lastFrames = frameBuffer
        return frameBuffer
    }

    /// The composition the engine plays at shown-time `t`: as authored, in
    /// the song's colours, or crossfading between the two on the way to the
    /// one. Re-plans only when what the room wears actually changes.
    private func wornComposition(at t: Double, beat: BeatSnapshot) -> Composer2Composition {
        if paintChange == nil, !paintTargetDirty, let worn { return worn }
        if paintTargetDirty {
            paintTarget = _songSwatches.map { Composer2AlbumPalette.apply(_composition, swatches: $0) }
            paintTargetDirty = false
            if swatchesChanged {
                swatchesChanged = false
                // A new song's colours — or the look's own again — land on
                // the one; with no grid they fade; with no clock at all (a
                // preview) or nothing on yet they apply at once.
                if let current = worn, t > 0, t.isFinite {
                    if let landing = Composer2Quantizer.landing(after: t, beat: beat) {
                        paintChange = (current, landing.time, Composer2Quantizer.preroll(for: beat))
                    } else {
                        paintChange = (current, t + Self.paintFade, Self.paintFade)
                    }
                } else {
                    paintChange = nil
                }
            }
        }
        let target = paintTarget ?? _composition
        var next = target
        if let change = paintChange {
            if !(t < change.landing) {
                paintChange = nil
            } else {
                let weight = Composer2Quantizer.weight(at: t, landing: change.landing, preroll: change.preroll)
                next = Composer2AlbumPalette.blend(change.from, target, t: weight)
            }
        }
        if next != worn {
            worn = next
            plansDirty = true
            derivedDirty = true
        }
        return next
    }

    private func installGeometry(count: Int, radial: [Double], angular: [Double],
                                 slots: [CompositionRenderSlot]) {
        // Composer 2.1: exact slots win. The orchestrator's own order carries
        // light identity, segments and real positions; nothing is reconstructed.
        if slots.count == count, count > 0 {
            if geometryFromBox, _liveSlots == slots, _geometry.count == count { return }
            _liveSlots = slots
            let ids = slots.map { $0.lightID ?? "slot-\($0.index)" }
            if slots.allSatisfy({ $0.position != nil }) {
                // The SAME floor-plan mapping the on-screen layout uses — the
                // raw bridge z here was the mirror image of the preview's.
                let positions = slots.map { (x: $0.position?.x ?? 0, y: $0.position?.y ?? 0, z: $0.position?.z ?? 0) }
                let usesHeight = Composer2FloorPlan.depthUsesHeight(positions)
                _geometry = Composer2SlotGeometry(
                    points: positions.map { Composer2FloorPlan.point(x: $0.x, y: $0.y, z: $0.z, depthUsesHeight: usesHeight) },
                    lightIDs: ids)
            } else if radial.count == count, angular.count == count {
                _geometry = Composer2SlotGeometry(radial: radial, angular: angular, lightIDs: ids)
            } else {
                _geometry = .linear(count: count, lightIDs: ids)
            }
            cachedRadial = radial
            cachedAngular = angular
            geometryFromBox = true
            plansDirty = true
            return
        }
        _liveSlots = []
        let usable = radial.count == count && angular.count == count && count > 0
        if usable {
            if geometryFromBox, cachedRadial == radial, cachedAngular == angular, _geometry.count == count { return }
            cachedRadial = radial
            cachedAngular = angular
            _geometry = Composer2SlotGeometry(radial: radial, angular: angular, lightIDs: _layoutLightIDs)
        } else {
            if geometryFromBox, _geometry.count == count, !_geometry.hasSpatialData { return }
            cachedRadial = []
            cachedAngular = []
            _geometry = .linear(count: count, lightIDs: _layoutLightIDs)
        }
        geometryFromBox = true
        plansDirty = true
    }

    // MARK: Legacy box mirroring

    /// The legacy reaction source that makes the orchestrator hold the
    /// microphone exactly when this composition needs it.
    func mirroredReactionSource() -> ReactionConfig.Source {
        locked {
            // Play Along always listens: the room's beat is the only true phase
            // (a music service's grid is a guess until the song's offset is
            // learned), and its loudness drives the swell — so the microphone is
            // held even while a music service drives the tempo.
            if _playAlongRequested { return .micAmplitude }
            if _composition.usesMicrophoneBands { return .micAmplitude }
            if _composition.usesBeatClock { return .beat }
            return .none
        }
    }
}

// MARK: - Flash shaper

/// Shapes Composer 2's frames to the photosensitivity budget BEFORE the
/// wire's gate sees them.
///
/// The wire gate (`BeatMath.FlashSafety.OnsetGate`) is the authority, and it
/// is strict in a way that matters for looks: a field-level rise of 10 %
/// luminance or more is an onset, onsets must be 0.34 s apart, and a refused
/// onset HOLDS the previous frame — so any smooth rise faster than ~0.3 of
/// full luminance a second (a twinkle in a one-light room, a firework's
/// bloom, a restroke) froze, then jumped. The shaper runs the same gate on
/// the same frames: when a frame would be held, it emits the largest blend
/// toward that frame the gate accepts instead. The rise keeps moving, only
/// as fast as the budget allows, and the wire gate is left with nothing to
/// hold. It never adds light or a flash — it only slows a rise.
struct Composer2FlashShaper {
    private var gate = BeatMath.FlashSafety.OnsetGate()
    private var last: [Composer2Frame] = []
    private var lastTime: Double?
    /// Frames the shaper had to slow (for tests and diagnostics).
    private(set) var shapedFrames = 0
    private(set) var totalFrames = 0

    /// A pause longer than this starts over (the wire has moved on).
    static let pauseReset: Double = 0.3
    private static let source = "composer2"

    mutating func reset() {
        self = Composer2FlashShaper()
    }

    mutating func shape(_ frames: [Composer2Frame], at t: Double) -> [Composer2Frame] {
        guard !frames.isEmpty, t.isFinite else { return frames }
        if frames.count != last.count
            || lastTime.map({ t < $0 || t - $0 > Composer2FlashShaper.pauseReset }) ?? false {
            let shaped = shapedFrames, total = totalFrames
            reset()
            shapedFrames = shaped
            totalFrames = total
        }
        totalFrames += 1
        lastTime = t
        var probe = gate
        let direct = probe.admit(frame: Composer2FlashShaper.field(frames), source: Composer2FlashShaper.source, at: t)
        if direct.wasAdmitted || last.isEmpty {
            probe.commit(direct, delivered: true, at: t)
            gate = probe
            last = frames
            return frames
        }
        // The largest step toward the new frame that the gate would emit.
        var lo = 0.0, hi = 1.0
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            var trial = gate
            let r = trial.admit(frame: Composer2FlashShaper.field(Composer2FlashShaper.blend(last, frames, mid)),
                                source: Composer2FlashShaper.source, at: t)
            if r.wasAdmitted { lo = mid } else { hi = mid }
        }
        let out = Composer2FlashShaper.blend(last, frames, lo)
        var commit = gate
        let r = commit.admit(frame: Composer2FlashShaper.field(out), source: Composer2FlashShaper.source, at: t)
        commit.commit(r, delivered: true, at: t)
        gate = commit
        last = out
        shapedFrames += 1
        return out
    }

    static func field(_ frames: [Composer2Frame]) -> BeatMath.FlashSafety.WireFrame {
        BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
    }

    static func blend(_ a: [Composer2Frame], _ b: [Composer2Frame], _ t: Double) -> [Composer2Frame] {
        zip(a, b).map { from, to in
            Composer2Frame(slot: to.slot,
                           x: Composer2Math.lerp(from.x, to.x, t),
                           y: Composer2Math.lerp(from.y, to.y, t),
                           brightness: Composer2Math.clamp01(Composer2Math.lerp(from.brightness, to.brightness, t)))
        }
    }
}
