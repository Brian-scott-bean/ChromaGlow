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
    var liveMirrorWindow: Double = 0.4

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
enum Composer2Heartbeat {
    enum Verdict: Equatable { case alive, reconnecting, ended }

    static let silenceTolerance: Double = 1.0
    static let reconnectTolerance: Double = 8.0

    static func verdict(lastLiveRenderAt: Double, startedAt: Double, now: Double, roomStillClaimed: Bool) -> Verdict {
        let silent = now - max(lastLiveRenderAt, startedAt)
        if silent < silenceTolerance { return .alive }
        if !roomStillClaimed { return .ended }
        return silent < reconnectTolerance ? .reconnecting : .ended
    }
}
