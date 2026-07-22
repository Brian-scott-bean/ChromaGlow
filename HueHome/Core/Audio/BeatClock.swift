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
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
        Self.mirrorLock.lock()
        Self.mirror = snap
        Self.mirrorLock.unlock()
    }

    init() {}

    // MARK: - User controls

    /// Register one tap. BPM = median of the last few tap intervals; the
    /// tap itself re-anchors the beat phase (a tap IS a beat).
    func tap(now: Double = CACurrentMediaTime()) {
        if let last = tapTimes.last, now - last > Self.tapResetGap {
            tapTimes = []
        }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }

        beatEpoch = now   // every tap re-anchors phase
        guard tapTimes.count >= 2 else {
            source = .tap
            isPinned = true
            publishMirror()
            return
        }
        var intervals: [Double] = []
        for i in 1..<tapTimes.count { intervals.append(tapTimes[i] - tapTimes[i - 1]) }
        intervals.sort()
        let median = intervals[intervals.count / 2]
        if median > 0.2, median < 2.0 {   // 30–300 BPM sanity window
            bpm = 60.0 / median
            confidence = 1.0
        }
        source = .tap
        isPinned = true
        publishMirror()
    }

    /// Set an explicit BPM (pins the clock).
    func setBPM(_ newBPM: Double, now: Double = CACurrentMediaTime()) {
        bpm = min(300, max(20, newBPM))
        if beatEpoch == 0 { beatEpoch = now }
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

    /// Full reset (session end).
    func clear() {
        bpm = 0; confidence = 0; source = .none; isPinned = false
        tapTimes = []; beatEpoch = 0; serviceHold = false
        lastServiceDriveAt = 0
        publishMirror()
    }

    // MARK: - Service drive (~1 Hz from MusicSessionCoordinator)

    /// Track-metadata drive: a playing track's position plus a known BPM
    /// steer the clock. The beat grid is anchored at track t=0 (sidecar
    /// BPMs carry no phase). Explicit tap/manual pins always win; re-poll
    /// jitter is absorbed as gentle ≤30 ms corrections; a phase error
    /// beyond serviceResyncThreshold (seek, track change) re-anchors
    /// outright. Out-of-range BPMs are rejected, not clamped — a bad
    /// sidecar value must not bend the clock.
    func driveFromTrack(bpm newBPM: Double, position: PlaybackPosition,
                        confidence newConfidence: Double = 1.0,
                        now: Double = CACurrentMediaTime()) {
        guard !isPinned else { return }
        guard position.isPlaying, newBPM >= 20, newBPM <= 300 else { return }
        serviceHold = true
        lastServiceDriveAt = now

        let interval = 60.0 / newBPM
        let positionSec = Double(position.positionMs) / 1000.0 + (now - position.capturedAt)
        let candidateEpoch = now - positionSec

        if source != .service || bpm == 0 {
            // Entering service drive: adopt tempo + phase outright.
            bpm = newBPM
            confidence = newConfidence
            source = .service
            beatEpoch = candidateEpoch
            publishMirror()
            return
        }

        if bpm != newBPM { bpm = newBPM }
        if confidence != newConfidence { confidence = newConfidence }

        // Signed error in seconds: how far the track's grid sits from ours,
        // wrapped to ±half-beat (same semantics as the audio ingest path).
        let snap = BeatSnapshot(bpm: bpm, beatEpoch: beatEpoch, beatsPerBar: beatsPerBar)
        var error = snap.beatPhase(at: candidateEpoch) * interval
        if error > interval / 2 { error -= interval }

        if abs(error) > Self.serviceResyncThreshold {
            beatEpoch = candidateEpoch
        } else {
            beatEpoch += min(Self.maxPhaseCorrection, max(-Self.maxPhaseCorrection, error))
        }
        publishMirror()
    }

    /// End the track-metadata drive (pause, track gone, session end). Keeps
    /// the last tempo running and returns the clock to audio-follow — the
    /// mic pass re-adopts tempo on its next confident estimate.
    func endServiceDrive() {
        guard serviceHold || source == .service else { return }
        serviceHold = false
        if source == .service { source = bpm > 0 ? .audio : .none }
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
                publishMirror()
                return   // tempo, source, and confidence stay the service's
            }
        }
        confidence = estimate.confidence
        guard !isPinned else { return }
        guard estimate.confidence >= Self.minAudioConfidence, estimate.bpm > 0 else { return }

        let audioLastBeat = endTime - estimate.lastBeatOffset

        if bpm == 0 || source != .audio {
            // First audio lock: adopt tempo + phase outright.
            bpm = estimate.bpm
            beatEpoch = audioLastBeat
            source = .audio
            publishMirror()
            return
        }

        bpm = estimate.bpm

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
        publishMirror()
    }
}
