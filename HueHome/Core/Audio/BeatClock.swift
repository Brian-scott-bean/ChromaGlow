// BeatClock.swift
// ChromaGlow — Core/Audio (DJ upgrade Phase 2)
//
// The single tempo authority. Tap tempo, manual BPM, and audio-detected
// BPM all drive the SAME clock; render loops read an immutable BeatSnapshot
// from a lock-guarded static mirror and extrapolate beat phase at render
// time — beat position is never sampled, so 25 fps output stays locked
// between ~2 Hz tempo updates.
//
// Rules:
//  • tap()/setBPM() pin the clock — audio may not override until unpin().
//  • Audio drives only when unpinned and confidence > 0.5.
//  • Audio phase corrections are applied as gentle epoch adjustments
//    (≤30 ms per correction) so lights never visibly jump.

import Foundation
import QuartzCore
import os

// MARK: - BeatSnapshot

/// Immutable clock snapshot. All times are in the CACurrentMediaTime
/// timebase. bpm == 0 means "no clock" — consumers fall back to their
/// non-beat behavior.
struct BeatSnapshot: Sendable, Equatable {
    var bpm: Double = 0
    var beatEpoch: Double = 0     // host time of beat 0 (bar-aligned)
    var beatsPerBar: Int = 4
    /// 0–1: how sure the grid's beats sit where the music's beats are. Taps
    /// and a phase-locked microphone are sure; a music service's guess that
    /// beat 1 falls at track t=0 is not.
    var phaseConfidence: Double = 0
    /// 0–1: how sure beat 0 of each bar is "the one".
    var barConfidence: Double = 0

    static let none = BeatSnapshot()

    var beatInterval: Double { bpm > 0 ? 60.0 / bpm : 0 }

    /// 0..<1 position within the current beat (0 when no clock).
    func beatPhase(at t: Double) -> Double {
        guard bpm > 0 else { return 0 }
        let beats = (t - beatEpoch) / beatInterval
        let frac = beats - floor(beats)
        return frac < 0 ? frac + 1 : frac
    }

    /// Whole beats elapsed since the epoch (negative before it).
    func beatIndex(at t: Double) -> Int {
        guard bpm > 0 else { return 0 }
        return Int(floor((t - beatEpoch) / beatInterval))
    }

    /// 0..<1 position within the current bar.
    func barPhase(at t: Double) -> Double {
        guard bpm > 0, beatsPerBar > 0 else { return 0 }
        let bars = (t - beatEpoch) / (beatInterval * Double(beatsPerBar))
        let frac = bars - floor(bars)
        return frac < 0 ? frac + 1 : frac
    }

    /// Seconds since the most recent beat boundary.
    func timeSinceBeat(at t: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return beatPhase(at: t) * beatInterval
    }
}

// MARK: - BeatClock

@MainActor
@Observable
final class BeatClock {
    static let shared = BeatClock()

    enum DriveSource: String {
        case none, tap, manual, audio, service

        /// User-facing word — "service" is developer vocabulary; the drive
        /// fed by a music source reads as "Music" everywhere visible.
        var displayName: String {
            switch self {
            case .none: "None"
            case .tap: "Tap"
            case .manual: "Manual"
            case .audio: "Audio"
            case .service: "Music"
            }
        }
    }

    // Observable state (UI reads these).
    private(set) var bpm: Double = 0
    private(set) var confidence: Double = 0
    private(set) var source: DriveSource = .none
    private(set) var isPinned = false
    private(set) var beatsPerBar = 4
    /// See `BeatSnapshot.phaseConfidence` / `barConfidence`.
    private(set) var phaseConfidence: Double = 0
    private(set) var barConfidence: Double = 0

    // Tap-tempo state.
    private var tapTimes: [Double] = []
    /// Taps further apart than this start a fresh measurement.
    private static let tapResetGap: Double = 2.5
    /// Maximum epoch correction per audio ingest (seconds).
    private static let maxPhaseCorrection = 0.030
    /// Audio estimates below this confidence never drive the clock.
    private static let minAudioConfidence = 0.5
    /// A service-drive phase error beyond this is a seek/track change —
    /// re-anchor outright instead of creeping there 30 ms at a time.
    private static let serviceResyncThreshold = 0.120

    private var beatEpoch: Double = 0
    /// True while a music-service metadata drive owns the clock (a track is
    /// playing with a known BPM). Audio ingest may not steal the tempo —
    /// or the confidence display — while held; it MAY nudge phase (see
    /// ingest: a sidecar BPM carries no phase, the mic is the only true
    /// phase anchor). Not observed by any view.
    private var serviceHold = false
    /// Host time of the last driveFromTrack — a drive whose source died
    /// without endServiceDrive() self-heals after serviceDriveTimeout.
    private var lastServiceDriveAt: Double = 0
    private static let serviceDriveTimeout = 10.0

    // ── Bar ("the one") ──
    /// The user named the one (`resyncDownbeat`): no tracker guess may move it.
    private var barSetByUser = false
    /// A bar re-label the tracker proposes, and how many passes in a row it won.
    private var pendingBarShift = 0
    private var pendingBarRuns = 0
    private static let barRunsToShift = 3
    private static let minBarConfidence = 0.15

    // ── Lock health (the tracker drive) ──
    /// A pass with no beat it trusts fades the grid's confidences, halving
    /// every `confidenceHalfLife` seconds after `fadeGrace` (one bad pass in
    /// a drum fill fades nothing; a solid 0.9 lock reads below the usable
    /// 0.5 about 2.3 s into silence). They used to stay at the last lock's
    /// values forever: Play Along kept punching on a ghost grid, the readout
    /// kept its BPM, and the director's 20 s release never fired.
    private static let confidenceHalfLife = 1.5
    private static let fadeGrace = 1.0
    /// Capture time of the last tracker pass that drove the clock (tempo
    /// confidence ≥ minAudioConfidence), and of the last fade step.
    private var lastAudioDriveAt: Double = -.infinity
    private var lastFadeAt: Double = -.infinity
    /// A phase error past this (or a sixth of a beat, if smaller) is a new
    /// song or a seek, not drift. It used to creep 30 ms a pass — about 5 s
    /// of punches off the beat for half a beat of error, while the readout
    /// claimed a lock.
    private static let relockThreshold = 0.070
    /// A second pass whose error agrees within this confirms a large one.
    private static let relockAgreement = 0.035
    /// Reported while a large error waits for its confirming pass: below
    /// usable, so nothing engages on (or claims) a grid that is about to move.
    private static let relockingPhaseConfidence = 0.4
    /// A tracker tempo this far from the clock's is another song (drift is
    /// far smaller, and the tracker needs three passes to change its mind).
    private static let newTempoRatio = 0.03
    /// Nothing drove the clock for this long: the next confident pass is
    /// trusted at once instead of waiting for a second opinion.
    private static let lockForgetAfter = 3.0
    private var pendingRelockError: Double?

    /// Read by the mic-demand evaluator: a `.beat` reaction needs no
    /// microphone while a music service drives the clock. Stale-aware:
    /// a hold whose drive stopped refreshing (dead source, or a track
    /// change whose tempo never resolved) stops reporting service-driven
    /// after serviceDriveTimeout. Without this, the suppressed mic is
    /// the only thing that could run ingest's self-heal — the flag that
    /// blocks the mic would be the flag only the mic can clear.
    var isServiceDriven: Bool { isServiceDriven(now: CACurrentMediaTime()) }

    func isServiceDriven(now: Double) -> Bool {
        serviceHold && now - lastServiceDriveAt <= Self.serviceDriveTimeout
    }

    // ── Lock-guarded static mirror for render loops ──
    nonisolated private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var mirror = BeatSnapshot.none

    /// Read the current clock from any thread (render loops, audio thread).
    nonisolated static func snapshot() -> BeatSnapshot {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirror
    }

    private func publishMirror() {
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar,
                                phaseConfidence: phaseConfidence, barConfidence: barConfidence)
        Self.mirrorLock.lock()
        Self.mirror = snap
        Self.mirrorLock.unlock()
    }

    init() {}

    // MARK: - User controls

    /// Register one tap. BPM = median of the last few tap intervals; the
    /// tap itself re-anchors the beat phase (a tap IS a beat).
    ///
    /// The clock pins only once the taps have MEASURED a tempo — two or more
    /// taps inside the 30–300 BPM window. A pinned clock ignores the mic until
    /// "Auto", so pinning on the first tap let one stray tap freeze the clock:
    /// at 0 BPM ("Listening for a beat…" forever) when nothing had locked yet,
    /// or on a re-anchored phase the audio could no longer correct. A lone tap
    /// now only starts the measurement — except on a clock the user already
    /// owns (a tap/manual pin with a tempo), where it re-anchors the phase as
    /// every tap always has.
    func tap(now: Double = CACurrentMediaTime()) {
        if let last = tapTimes.last, now - last > Self.tapResetGap {
            tapTimes = []
        }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }

        guard let tappedBPM = measuredTapBPM() else {
            if isPinned, bpm > 0 {
                beatEpoch = now
                publishMirror()
            }
            return
        }
        bpm = tappedBPM
        confidence = 1.0
        beatEpoch = now   // the tap re-anchors phase
        phaseConfidence = 1
        if !barSetByUser { barConfidence = 0 }
        source = .tap
        isPinned = true
        publishMirror()
    }

    /// Median tap interval as a BPM, or nil until at least two taps inside
    /// the 30–300 BPM sanity window have measured one.
    private func measuredTapBPM() -> Double? {
        guard tapTimes.count >= 2 else { return nil }
        var intervals: [Double] = []
        for i in 1..<tapTimes.count { intervals.append(tapTimes[i] - tapTimes[i - 1]) }
        intervals.sort()
        let median = intervals[intervals.count / 2]
        guard median > 0.2, median < 2.0 else { return nil }   // 30–300 BPM sanity window
        return 60.0 / median
    }

    /// Set an explicit BPM (pins the clock). The beat position at `now` is
    /// kept: the ±1 BPM buttons and a Tap Dial twist change the tempo from
    /// here on, they do not jump the lights to a different beat or bar.
    func setBPM(_ newBPM: Double, now: Double = CACurrentMediaTime()) {
        if beatEpoch == 0 { beatEpoch = now }
        retime(to: min(300, max(20, newBPM)), keepingPhaseAt: now)
        confidence = 1.0
        source = .manual
        isPinned = true
        publishMirror()
    }

    /// DJ nudge: shift phase earlier/later by milliseconds.
    func nudgePhase(ms: Double) {
        beatEpoch += ms / 1000.0
        publishMirror()
    }

    /// Declare "now" to be beat 1 of the bar (re-anchors bar alignment).
    func resyncDownbeat(now: Double = CACurrentMediaTime()) {
        beatEpoch = now
        // The user named the one: it outranks every guess until the song
        // changes (`endServiceDrive(trackChanged:)`) or the clock is cleared.
        barConfidence = 1
        barSetByUser = true
        if bpm > 0 { phaseConfidence = 1 }
        publishMirror()
    }

    /// "Tap the one" (Play Along): the beat nearest `now` becomes a bar start.
    /// Only the bar LABEL moves, by whole beats — a tap's own timing error
    /// never shifts a beat. With no running beat it declares `now` the
    /// downbeat, like `resyncDownbeat`.
    func markDownbeat(near now: Double = CACurrentMediaTime()) {
        guard bpm > 0, beatEpoch != 0 else {
            resyncDownbeat(now: now)
            return
        }
        let interval = 60.0 / bpm
        let nearest = ((now - beatEpoch) / interval).rounded()
        guard nearest.isFinite, abs(nearest) < 1e9 else { return }
        let perBar = max(1, beatsPerBar)
        let shift = ((Int(nearest) % perBar) + perBar) % perBar
        beatEpoch += Double(shift) * interval
        if let offset = serviceBeatOffset {
            // The track's grid moves with the one the user named, so a
            // re-anchor (seek) keeps it and the song memory learns it.
            serviceBeatOffset = Self.wrapped(offset + Double(shift) * interval, interval * Double(perBar))
        }
        barConfidence = 1
        barSetByUser = true
        pendingBarShift = 0
        pendingBarRuns = 0
        publishMirror()
    }

    /// Set the bar length (time-signature numerator). Clamped 1…12.
    func setBeatsPerBar(_ n: Int) {
        beatsPerBar = min(12, max(1, n))
        publishMirror()
    }

    /// Return to audio-follow (or the service drive, if one is active).
    func unpin(now: Double = CACurrentMediaTime()) {
        isPinned = false
        tapTimes = []
        if source == .tap || source == .manual {
            // Stale-aware: while pinned, driveFromTrack early-returns and
            // stops refreshing the hold — a session that died mid-pin must
            // not leave the label on "Music" with nothing driving.
            source = isServiceDriven(now: now) ? .service : (bpm > 0 ? .audio : .none)
        }
    }

    /// Change the tempo WITHOUT moving the beat position at `pivot`.
    ///
    /// Phase is `(t − beatEpoch) / beatInterval`, so replacing the interval
    /// under a fixed epoch rescales every beat since the epoch: a change of δ
    /// BPM shifts the phase at `t` by `(t − beatEpoch) · δ / 60` beats. Five
    /// minutes into a set, a 0.3 BPM audio drift is a 1.5-beat jump; a ±1 BPM
    /// press, 5. The epoch is therefore re-based so the beat count at `pivot`
    /// — whole beats, phase and bar — is identical under the new interval.
    ///
    /// NOT used by `driveFromTrack`: there the epoch IS track t=0 and a new
    /// sidecar BPM re-states the grid from that anchor by design.
    private func retime(to newBPM: Double, keepingPhaseAt pivot: Double) {
        if bpm > 0, newBPM > 0, newBPM != bpm, pivot.isFinite {
            let beatsAtPivot = (pivot - beatEpoch) * bpm / 60.0
            beatEpoch = pivot - beatsAtPivot * 60.0 / newBPM
        }
        bpm = newBPM
    }

    /// Full reset (session end).
    func clear() {
        bpm = 0; confidence = 0; source = .none; isPinned = false
        tapTimes = []; beatEpoch = 0; serviceHold = false
        lastServiceDriveAt = 0
        phaseConfidence = 0; barConfidence = 0; barSetByUser = false
        pendingBarShift = 0; pendingBarRuns = 0
        lastAudioDriveAt = -.infinity; lastFadeAt = -.infinity
        pendingRelockError = nil
        resetServiceOffset()
        publishMirror()
    }

    /// The microphone stopped (no one needs it, a route change, the app
    /// went quiet). A grid the mic owned is only a memory now: its
    /// confidences go to zero so the next session — or Play Along switched
    /// on later — waits for a beat it hears instead of engaging at once on
    /// a stale one. The tempo coasts. A pin, a tap and a music-service
    /// drive own their own grids and keep them.
    func audioStopped() {
        guard !isPinned, source == .audio else { return }
        confidence = 0
        phaseConfidence = 0
        if !barSetByUser { barConfidence = 0 }
        lastAudioDriveAt = -.infinity
        lastFadeAt = -.infinity
        publishMirror()
    }

    /// A tracker pass that found no beat at all (silence, speech, a quiet
    /// passage). The grid coasts at its last tempo; its confidences fade.
    func noteNoBeat(at now: Double = CACurrentMediaTime()) {
        guard !isPinned, source == .audio, !isServiceDriven(now: now) else { return }
        fadeConfidence(to: now)
    }

    private func fadeConfidence(to now: Double) {
        let since = max(lastAudioDriveAt + Self.fadeGrace, lastFadeAt)
        guard since.isFinite, now > since else { return }
        lastFadeAt = now
        let k = pow(0.5, (now - since) / Self.confidenceHalfLife)
        confidence *= k
        phaseConfidence *= k
        if !barSetByUser { barConfidence *= k }
        publishMirror()
    }

    // MARK: - Service drive (~1 Hz from MusicSessionCoordinator)

    /// Where the track's beat grid sits relative to track t=0, in seconds,
    /// modulo one BAR (so it carries the bar label as well as the phase).
    /// Songs rarely start on a beat: the drive used to assume they always
    /// did, and with the microphone pulling toward the true beat the two
    /// fought — 70–130 ms off in docs/ios/play-along/beatlab. Learned from the
    /// mic while a track plays (or handed in from the song memory) and
    /// cleared on a track change; a seek keeps it, because it is
    /// track-relative.
    private(set) var serviceBeatOffset: Double?
    /// Confident mic passes that agreed with the grid (minus disagreements).
    private var serviceOffsetAgreement = 0
    /// The service grid's t=0 anchor as of the latest drive.
    private var lastServiceCandidateEpoch: Double?
    /// Capture time of the latest confident mic phase (this track).
    private var lastMicPhaseAt: Double = -.infinity
    /// Passes the offset must agree on before the drive trusts it.
    private static let offsetAgreementToTrust = 6
    private static let offsetAgreementTolerance = 0.015
    /// While the mic has spoken within this window, an untrusted service grid
    /// drives tempo only.
    private static let micPhaseFreshness = 2.0
    /// A service grid's own phase and bar are guesses (beat 1 at t=0).
    private static let serviceGuessPhaseConfidence = 0.3
    private static let serviceGuessBarConfidence = 0.2
    /// The one, as the song memory remembered it.
    private static let rememberedBarConfidence = 0.6
    /// The microphone has agreed with the current offset at least once — an
    /// offset the song memory handed in is not yet evidence FOR the memory.
    private var offsetConfirmedByMic = false

    private var serviceOffsetTrusted: Bool { serviceOffsetAgreement >= Self.offsetAgreementToTrust }

    private func resetServiceOffset() {
        serviceBeatOffset = nil
        serviceOffsetAgreement = 0
        offsetConfirmedByMic = false
        lastServiceCandidateEpoch = nil
        lastMicPhaseAt = -.infinity
    }

    /// The track's beat offset (modulo one bar) while the microphone keeps
    /// confirming it — what the song memory learns. nil until the mic has
    /// agreed often enough to trust it, and again once the mic goes quiet.
    func confirmedServiceOffset(now: Double = CACurrentMediaTime()) -> Double? {
        guard serviceHold, serviceOffsetTrusted, offsetConfirmedByMic,
              now - lastMicPhaseAt < Self.micPhaseFreshness else { return nil }
        return serviceBeatOffset
    }

    private static func wrapped(_ x: Double, _ m: Double) -> Double {
        guard m > 0, x.isFinite else { return 0 }
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    /// Track-metadata drive: a playing track's position plus a known BPM
    /// steer the clock. Explicit tap/manual pins always win; re-poll jitter is
    /// absorbed as gentle ≤30 ms corrections; a phase error beyond
    /// serviceResyncThreshold (seek, track change) re-anchors outright.
    /// Out-of-range BPMs are rejected, not clamped — a bad sidecar value must
    /// not bend the clock.
    ///
    /// The grid's anchor is track t=0 plus the track's beat offset once that
    /// offset is trusted (`beatOffset` from the song memory, or learned from
    /// the mic). Until then, while the mic is phase-locked, the service drives
    /// tempo only — the mic owns the phase and nothing fights.
    func driveFromTrack(bpm newBPM: Double, position: PlaybackPosition,
                        confidence newConfidence: Double = 1.0,
                        beatOffset knownOffset: Double? = nil,
                        barKnown: Bool = true,
                        now: Double = CACurrentMediaTime()) {
        guard position.isPlaying, newBPM >= 20, newBPM <= 300 else { return }
        // Refresh the hold BEFORE the pin guard: a pinned clock still knows
        // the service is alive. Guarding first let any pin held >10s make a
        // live drive look stale — the mic spun up for nothing and unpin()
        // fell to .audio instead of returning to the track.
        serviceHold = true
        lastServiceDriveAt = now
        guard !isPinned else { return }

        let interval = 60.0 / newBPM
        let positionSec = Double(position.positionMs) / 1000.0 + (now - position.capturedAt)
        let candidateEpoch = now - positionSec
        lastServiceCandidateEpoch = candidateEpoch
        if serviceBeatOffset == nil, let knownOffset, knownOffset.isFinite {
            // The song memory's grid for this track on this route: trusted at
            // once, and the one with it when the memory knew where bars start
            // (`barKnown`; otherwise the offset names a beat, not a bar).
            serviceBeatOffset = Self.wrapped(knownOffset, interval * Double(max(1, beatsPerBar)))
            serviceOffsetAgreement = Self.offsetAgreementToTrust
            offsetConfirmedByMic = false
            if barKnown, !barSetByUser { barConfidence = max(barConfidence, Self.rememberedBarConfidence) }
        }
        let trusted = serviceOffsetTrusted
        let target = candidateEpoch + (trusted ? (serviceBeatOffset ?? 0) : 0)

        if source != .service || bpm == 0 {
            // The microphone already hears this song's beat and the track's
            // offset is not known yet: keep the mic's phase, take the
            // service's tempo. Jumping to the t=0 guess here threw away a lock
            // the room could see, then crept back 30 ms a pass.
            if !trusted, source == .audio, bpm > 0, now - lastMicPhaseAt < Self.micPhaseFreshness,
               abs(bpm / newBPM - 1) < 0.03 {
                retime(to: newBPM, keepingPhaseAt: now)
                confidence = newConfidence
                source = .service
                publishMirror()
                return
            }
            // Entering service drive: adopt tempo + phase outright.
            bpm = newBPM
            confidence = newConfidence
            source = .service
            beatEpoch = target
            phaseConfidence = trusted ? 0.9 : Self.serviceGuessPhaseConfidence
            // A trusted offset keeps whatever the clock knows of the bar (the
            // memory raised it above when it knew the one); a t=0 guess knows
            // nothing.
            if !barSetByUser, !trusted { barConfidence = Self.serviceGuessBarConfidence }
            publishMirror()
            return
        }

        if bpm != newBPM { bpm = newBPM }
        if confidence != newConfidence { confidence = newConfidence }

        // The mic holds the phase and the track's offset is not yet trusted:
        // re-anchoring to t=0 here is the tug of war the mic used to lose.
        if !trusted, now - lastMicPhaseAt < Self.micPhaseFreshness {
            publishMirror()
            return
        }

        // Signed error in seconds: how far the track's grid sits from ours,
        // wrapped to ±half-beat (same semantics as the audio ingest path).
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
        var error = snap.beatPhase(at: target) * interval
        if error > interval / 2 { error -= interval }

        // The wrap caps |error| at interval/2, which sits below the fixed
        // 120ms threshold once BPM ≥ 250 — a seek would only ever creep at
        // ≤30ms per drive (seconds of visible lag). Scale the re-anchor
        // trigger down with the interval so fast tempos still snap.
        let resyncThreshold = min(Self.serviceResyncThreshold, interval / 4)
        if abs(error) > resyncThreshold {
            beatEpoch = target
        } else {
            beatEpoch += min(Self.maxPhaseCorrection, max(-Self.maxPhaseCorrection, error))
        }
        publishMirror()
    }

    /// End the track-metadata drive (pause, track gone, session end). Keeps
    /// the last tempo running and returns the clock to audio-follow — the
    /// mic pass re-adopts tempo on its next confident estimate. A TRACK
    /// change also forgets the track's beat offset and any downbeat the user
    /// named for it; a pause keeps both.
    func endServiceDrive(trackChanged: Bool = false) {
        if trackChanged {
            resetServiceOffset()
            // The last song's one says nothing about the next song's.
            barSetByUser = false
            barConfidence = 0
            pendingBarShift = 0
            pendingBarRuns = 0
            publishMirror()
        }
        guard serviceHold || source == .service else { return }
        serviceHold = false
        if source == .service { source = bpm > 0 ? .audio : .none }
    }

    /// After a confident mic correction under a service hold: remember where
    /// the grid sits relative to the track and count whether the mic agreed.
    private func learnServiceOffset(residual: Double) {
        guard let candidate = lastServiceCandidateEpoch, bpm > 0 else { return }
        let bar = 60.0 / bpm * Double(max(1, beatsPerBar))
        serviceBeatOffset = Self.wrapped(beatEpoch - candidate, bar)
        if abs(residual) < Self.offsetAgreementTolerance {
            serviceOffsetAgreement += 1
            offsetConfirmedByMic = true
        } else {
            serviceOffsetAgreement = max(0, serviceOffsetAgreement - 2)
        }
    }

    // MARK: - Audio drive (~2 Hz from the tempo pass)

    /// Feed an audio tempo estimate. Ignored while pinned (except that the
    /// confidence display still updates so the UI can show what audio hears).
    /// While a service drive holds the clock, the track's known BPM outranks
    /// what the microphone guesses — but the mic's observed beat is the only
    /// true PHASE anchor (a sidecar BPM carries none), so a confident
    /// estimate still applies a gentle phase-only correction. The mic is
    /// never demanded for this; it assists only when already running.
    func ingest(estimate: TempoEstimate, endTime: Double) {
        if serviceHold {
            if endTime - lastServiceDriveAt > Self.serviceDriveTimeout {
                // Self-heal: the driving source died without endServiceDrive.
                serviceHold = false
                if source == .service { source = bpm > 0 ? .audio : .none }
                // Fall through — audio-follow resumes normally below.
            } else if isPinned {
                // A pin owns phase outright — the mic may not nudge a
                // pinned epoch, and the service keeps the confidence
                // display. tap() deliberately leaves serviceHold set, so
                // this branch is reachable (pin during a live track).
                return
            } else {
                guard estimate.confidence >= Self.minAudioConfidence, bpm > 0 else { return }
                let interval = 60.0 / bpm
                let audioLastBeat = endTime - estimate.lastBeatOffset
                let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
                var error = snap.beatPhase(at: audioLastBeat) * interval
                if error > interval / 2 { error -= interval }
                beatEpoch += min(Self.maxPhaseCorrection, max(-Self.maxPhaseCorrection, error))
                lastMicPhaseAt = endTime
                learnServiceOffset(residual: error)
                phaseConfidence = estimate.confidence
                publishMirror()
                return   // tempo, source, and confidence stay the service's
            }
        }
        confidence = estimate.confidence
        guard !isPinned else { return }
        guard estimate.confidence >= Self.minAudioConfidence, estimate.bpm > 0 else { return }

        let audioLastBeat = endTime - estimate.lastBeatOffset

        // The mic's estimate is clamped to the SAME 20…300 BPM window `tap()`
        // and `driveFromTrack` hold themselves to. It was not, and every
        // downstream consumer assumes it is: `BeatMath.cycleIndex` evaluates
        // `Int(floor(...))` on a position derived from `60 / bpm`, so a
        // pathological estimate (a near-zero BPM out of a noisy autocorrelation,
        // or an absurd one) makes the position enormous and the conversion TRAP
        // — on the render path, once per frame. The `> 0` guard above stops NaN
        // and negatives; it does nothing about 0.001 or 1e6.
        let clampedBPM = min(300, max(20, estimate.bpm))

        if bpm == 0 || source != .audio {
            // First audio lock: adopt tempo + phase outright.
            bpm = clampedBPM
            beatEpoch = audioLastBeat
            source = .audio
            phaseConfidence = estimate.confidence
            if !barSetByUser { barConfidence = 0 }
            publishMirror()
            return
        }

        // Tempo drift keeps the beat position at the analysis end time; the
        // gentle correction below is then measured against the grid a viewer
        // is actually seeing, not one the new BPM rescaled out from the epoch.
        retime(to: clampedBPM, keepingPhaseAt: endTime)

        // Gentle phase correction: move the epoch toward the audio-observed
        // beat by at most maxPhaseCorrection — never a visible jump.
        let interval = 60.0 / bpm
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
        let phaseAtAudioBeat = snap.beatPhase(at: audioLastBeat)
        // Signed error in seconds: how far the audio beat sits from our grid.
        var error = phaseAtAudioBeat * interval
        if error > interval / 2 { error -= interval }   // wrap to ±half-beat
        let correction = min(Self.maxPhaseCorrection, max(-Self.maxPhaseCorrection, error))
        beatEpoch += correction
        phaseConfidence = estimate.confidence
        publishMirror()
    }

    // MARK: - Beat tracker drive (Play Along P1, ~2 Hz)

    /// Feed a BeatTracker observation. The same ownership rules as
    /// `ingest(estimate:endTime:)`: a pin ignores it; a music-service hold
    /// keeps its tempo and accepts phase and bar corrections only. New here:
    /// the grid's phase and bar confidences, the bar label — a confident
    /// downbeat re-labels the grid by WHOLE beats, never moving a beat — and,
    /// under a service hold, learning the track's beat offset so the drive
    /// stops pulling the grid back to t=0.
    func ingest(observation o: BeatObservation) {
        guard o.bpm.isFinite, o.bpm > 0, o.lastBeat.isFinite else { return }
        if serviceHold {
            if o.lastBeat - lastServiceDriveAt > Self.serviceDriveTimeout {
                // Self-heal: the driving source died without endServiceDrive.
                serviceHold = false
                if source == .service { source = bpm > 0 ? .audio : .none }
                // Fall through — audio-follow resumes normally below.
            } else if isPinned {
                return
            } else {
                // The track's tempo stays the service's. A tracker at the same
                // tempo — or at half of it, whose beats are every other one of
                // ours — may correct the phase; one at double could be naming
                // the off-beats, so it may not.
                let ratio = bpm > 0 ? o.bpm / bpm : 0
                guard o.phaseConfidence >= Self.minAudioConfidence,
                      abs(ratio - 1) < 0.03 || abs(ratio - 0.5) < 0.015 else { return }
                let error = phaseError(of: o.lastBeat)
                let settled = correctPhase(error)
                lastMicPhaseAt = o.lastBeat
                lastAudioDriveAt = o.lastBeat
                learnServiceOffset(residual: error)
                phaseConfidence = settled ? o.phaseConfidence : min(o.phaseConfidence, Self.relockingPhaseConfidence)
                if abs(ratio - 1) < 0.03 { applyBar(o) }
                publishMirror()
                return
            }
        }
        guard !isPinned else {
            confidence = o.tempoConfidence
            return
        }
        guard o.tempoConfidence >= Self.minAudioConfidence else {
            // No beat it trusts: the grid coasts and its confidences fade
            // (this pass used to leave the phase confidence untouched).
            confidence = o.tempoConfidence
            if source == .audio { fadeConfidence(to: o.lastBeat) }
            return
        }
        confidence = o.tempoConfidence
        let resumed = o.lastBeat - lastAudioDriveAt > Self.lockForgetAfter
        lastAudioDriveAt = o.lastBeat
        // Same 20…300 window every other drive holds itself to (see ingest).
        let clampedBPM = min(300, max(20, o.bpm))
        let newTempo = bpm > 0 && abs(clampedBPM / bpm - 1) > Self.newTempoRatio

        if bpm == 0 || source != .audio || newTempo {
            // First lock — or another song: adopt tempo and phase outright,
            // and the bar when the tracker already has a confident opinion.
            // A new tempo used to be retimed onto the old grid and crept
            // there 30 ms a pass. The last song's one says nothing about
            // this one's.
            if newTempo { barSetByUser = false }
            bpm = clampedBPM
            beatEpoch = o.lastBeat
            source = .audio
            phaseConfidence = o.phaseConfidence
            if o.phaseConfidence >= Self.minAudioConfidence { lastMicPhaseAt = o.lastBeat }
            if !barSetByUser { barConfidence = 0 }
            pendingBarShift = 0
            pendingBarRuns = 0
            pendingRelockError = nil
            applyBar(o, immediately: true)
            publishMirror()
            return
        }

        retime(to: clampedBPM, keepingPhaseAt: o.lastBeat)
        var settled = true
        if o.phaseConfidence >= Self.minAudioConfidence {
            // After a gap the old grid is only a memory: its first
            // confident beat needs no second opinion.
            settled = correctPhase(phaseError(of: o.lastBeat), confirmed: resumed)
            lastMicPhaseAt = o.lastBeat
        }
        phaseConfidence = settled ? o.phaseConfidence : min(o.phaseConfidence, Self.relockingPhaseConfidence)
        applyBar(o)
        publishMirror()
    }

    /// Move the grid toward an observed beat `error` seconds away. Drift
    /// creeps at most 30 ms a pass, never a visible jump. A large error is a
    /// new song or a seek: one pass is held as a possible outlier (the grid
    /// does not move), and a second that agrees — or `confirmed` — snaps the
    /// nearest beat onto it. Snapping by less than half a beat keeps every
    /// beat's number, so the bar stays where it was. Returns false while a
    /// large error waits for its confirmation.
    private func correctPhase(_ error: Double, confirmed: Bool = false) -> Bool {
        guard bpm > 0, error.isFinite else { return true }
        let interval = 60.0 / bpm
        let threshold = min(Self.relockThreshold, interval / 6)
        guard abs(error) > threshold else {
            pendingRelockError = nil
            beatEpoch += min(Self.maxPhaseCorrection, max(-Self.maxPhaseCorrection, error))
            return true
        }
        var agreed = confirmed
        if !agreed, let pending = pendingRelockError {
            // Compared modulo a beat: near half a beat the wrapped sign flips.
            var d = error - pending
            d -= interval * (d / interval).rounded()
            agreed = abs(d) < Self.relockAgreement
        }
        guard agreed else {
            pendingRelockError = error
            return false
        }
        beatEpoch += error
        pendingRelockError = nil
        return true
    }

    /// Signed seconds from our nearest grid beat to `beat`, wrapped to
    /// ±half a beat (positive: our grid is early).
    private func phaseError(of beat: Double) -> Double {
        guard bpm > 0 else { return 0 }
        let interval = 60.0 / bpm
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
        var error = snap.beatPhase(at: beat) * interval
        if error > interval / 2 { error -= interval }
        return error
    }

    /// The tracker's bar: downbeats fall at beat indices ≡ `barSlot` (mod 4)
    /// counted from its last beat. Re-label the grid by whole beats once the
    /// same shift has won `barRunsToShift` passes in a row (or at once on a
    /// first lock). Agreement raises the bar confidence; a named one wins.
    private func applyBar(_ o: BeatObservation, immediately: Bool = false) {
        guard !barSetByUser, beatsPerBar == 4, bpm > 0, let slot = o.barSlot,
              o.barConfidence >= Self.minBarConfidence else { return }
        let interval = 60.0 / bpm
        let beatsSinceEpoch = (o.lastBeat - beatEpoch) / interval
        guard beatsSinceEpoch.isFinite, abs(beatsSinceEpoch) < 1e9 else { return }
        let n0 = Int(beatsSinceEpoch.rounded())
        let shift = ((n0 + slot) % 4 + 4) % 4
        if shift == 0 {
            pendingBarRuns = 0
            barConfidence += (o.barConfidence - barConfidence) * 0.3
            return
        }
        if shift == pendingBarShift {
            pendingBarRuns += 1
        } else {
            pendingBarShift = shift
            pendingBarRuns = 1
        }
        guard immediately || pendingBarRuns >= Self.barRunsToShift else { return }
        beatEpoch += Double(shift) * interval
        pendingBarShift = 0
        pendingBarRuns = 0
        barConfidence = o.barConfidence
    }
}
