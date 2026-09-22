// Composer2PreviewFeed.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// What the screen shows. While a live loop drives the runtime, the hero
// mirrors the frames that went to the lights; otherwise it evaluates the
// same runtime on its own clock. Either way every on-screen frame passes a
// preview-side onset gate, so the visualization obeys the same ≤3 flashes
// per second rule the wire does. Plain class, main-actor by convention.

import Foundation

final class Composer2PreviewFeed {
    let output: Composer2LiveOutput

    /// 1 normally; 0.5 under Reduce Motion.
    var timeScale: Double = 1
    /// How recently the live loop must have rendered for the hero to mirror it.
    ///
    /// Generous on purpose: the live loop and the preview share ONE engine
    /// state, and they run on different clocks (the orchestrator's elapsed
    /// time vs. the preview's own). Room mode renders a room only every
    /// 120 ms-plus, and with several rooms rotating (or a slow mailbox) the
    /// gap between two live renders can exceed half a second. Evaluating the
    /// shared state on the preview clock inside such a gap jumped the engine
    /// time backwards on the next live frame, which reset the state — event
    /// schedules included — so lightning could stop firing in Room mode.
    /// Inside this window the hero holds the last live frames instead. A stop
    /// (`releaseLiveGeometry`) zeroes the stamp, so previews resume at once.
    var liveMirrorWindow: Double = 3.0

    private var gate = BeatMath.FlashSafety.OnsetGate()
    private var lastShown: [Composer2Frame] = []
    private var clockOrigin: Double?
    private var clockAccumulated: Double = 0
    private var lastHostNow: Double?

    init(output: Composer2LiveOutput) {
        self.output = output
    }

    /// True when the live loop is currently feeding the runtime.
    func isMirroringLive(hostNow: Double) -> Bool {
        output.lastLiveRenderAt > 0 && hostNow - output.lastLiveRenderAt < liveMirrorWindow
    }

    /// Frames for the hero at host time `hostNow`.
    func displayFrames(hostNow: Double, features: AudioFeatures = .silent, beat: BeatSnapshot = .none) -> [Composer2Frame] {
        let frames: [Composer2Frame]
        if isMirroringLive(hostNow: hostNow) {
            frames = output.lastFrames
        } else {
            frames = output.evaluate(time: previewTime(hostNow: hostNow), features: features, beat: beat, hostNow: hostNow)
        }
        return admit(frames, at: hostNow)
    }

    /// Advance a preview clock that survives pauses without jumping.
    private func previewTime(hostNow: Double) -> Double {
        if let last = lastHostNow {
            let dt = Composer2Math.clamp(hostNow - last, 0, 0.5)
            clockAccumulated += dt * timeScale
        }
        lastHostNow = hostNow
        if clockOrigin == nil { clockOrigin = hostNow }
        return clockAccumulated
    }

    func resetClock() {
        clockOrigin = nil
        clockAccumulated = 0
        lastHostNow = nil
    }

    /// The realized-frame rule for the screen: a refusal holds the previous
    /// picture; it is a delay, never a skip.
    private func admit(_ frames: [Composer2Frame], at now: Double) -> [Composer2Frame] {
        guard !frames.isEmpty else { return frames }
        let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
        let reservation = gate.admit(frame: field, source: "composer2-preview", at: now,
                                     minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
        if reservation.wasAdmitted || lastShown.count != frames.count {
            lastShown = frames
        }
        gate.commit(reservation, delivered: true, at: now)
        return lastShown
    }
}

// MARK: - Heartbeat

/// Pure verdict on whether a live session is still being driven.
///
/// Two facts decide it, besides silence: whether the orchestrator still
/// renders OUR box (`drivingOurs`), and whether anything claims the room.
///  • Our box, rendering — alive. Our box, silent — reconnecting, then lost.
///  • Not our box, room claimed, silent — another look REPLACED ours: let go
///    at once, never stop it.
///  • Not our box, room unclaimed — a DTLS→REST failover drops the claim
///    before its awaits and re-claims when Room mode starts, so this is
///    "reconnecting" for the whole reconnect window; only after it is the
///    session LOST. (Ending it after one silent second let the failover
///    finish afterwards and play our look with no owner and no Stop.)
enum Composer2Heartbeat {
    enum Verdict: Equatable { case alive, reconnecting, replaced, lost }

    static let silenceTolerance: Double = 1.0
    static let reconnectTolerance: Double = 8.0

    static func verdict(lastLiveRenderAt: Double, startedAt: Double, now: Double,
                        roomStillClaimed: Bool, drivingOurs: Bool = true) -> Verdict {
        let silent = now - max(lastLiveRenderAt, startedAt)
        if silent < silenceTolerance { return .alive }
        if !drivingOurs && roomStillClaimed { return .replaced }
        return silent < reconnectTolerance ? .reconnecting : .lost
    }
}
