// BeatBinding.swift
// ChromaGlow — Core/Audio (Round 3: Universal Beat Panel)
//
// One shared way for ANY timing-driven loop (Effects tab, Studio cards,
// Perform pads) to lock its cycle to the app-wide BeatClock. Pure math —
// no I/O, no clocks of its own.
//
// Rules:
//  • Loops NEVER accumulate beat phase — every tick derives position from
//    BeatClock.snapshot(), so drift is impossible.
//  • mode == .off (or bpm == 0) means free-running: the loop's legacy
//    slider math applies unchanged.
//  • Flash-class loops (strobe) MUST pass their beatsPerCycle through
//    BeatMath.wcagSafeBeatsPerCycle before use (≤3 Hz photosensitivity cap).

import Foundation
import QuartzCore

// MARK: - BeatBinding

/// How a surface binds its effect cycle to the shared clock.
/// Persisted additively everywhere (presets, param state); decoding is
/// migration-safe — any missing/invalid field falls back to a sane value.
struct BeatBinding: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        case off          // legacy slider timing, byte-for-byte
        case beatLocked   // one cycle = beatsPerCycle beats of the shared clock
    }

    var mode: Mode = .off
    /// Beats per effect cycle. Allowed steps: ¼ ½ 1 2 4 8.
    var beatsPerCycle: Double = 1
    /// Shifts this surface's cycle relative to the downbeat, in beats.
    var phaseOffsetBeats: Double = 0

    static let off = BeatBinding()
    static let allowedSteps: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    static let phaseOffsetRange: ClosedRange<Double> = -8...8

    init(mode: Mode = .off, beatsPerCycle: Double = 1, phaseOffsetBeats: Double = 0) {
        self.mode = mode
        self.beatsPerCycle = Self.snappedStep(beatsPerCycle)
        self.phaseOffsetBeats = min(max(phaseOffsetBeats, Self.phaseOffsetRange.lowerBound),
                                    Self.phaseOffsetRange.upperBound)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .off
        let bpc = (try? c.decodeIfPresent(Double.self, forKey: .beatsPerCycle)) ?? 1
        let phase = (try? c.decodeIfPresent(Double.self, forKey: .phaseOffsetBeats)) ?? 0
        self.init(mode: mode, beatsPerCycle: bpc, phaseOffsetBeats: phase)
    }

    /// Nearest allowed step (persisted values can drift or be hand-edited).
    static func snappedStep(_ raw: Double) -> Double {
        guard raw.isFinite else { return 1 }
        return allowedSteps.min { abs($0 - raw) < abs($1 - raw) } ?? 1
    }

    var isActive: Bool { mode == .beatLocked }
}

// MARK: - BeatMath

/// Pure cycle math on top of BeatSnapshot. All times are in the snapshot's
/// timebase (CACurrentMediaTime). Callable from any thread.
enum BeatMath {

    /// True when the binding (or the clock) says "use legacy timing".
    static func isFreeRunning(_ binding: BeatBinding, snapshot: BeatSnapshot) -> Bool {
        !binding.isActive || snapshot.bpm <= 0
    }

    /// Largest-frequency-safe beats-per-cycle: walks the allowed steps UP
    /// from `requested` until the cycle rate is ≤ maxHz. WCAG 2.3.1 flash
    /// cap for strobe-class loops (174 BPM × ½-beat → ×1, for example).
    /// bpm ≤ 0 returns the snapped request (free-running loops self-cap
    /// through `FlashSafety.clampedHz`).
    static func wcagSafeBeatsPerCycle(requested: Double, bpm: Double, maxHz: Double = 3.0) -> Double {
        let snapped = BeatBinding.snappedStep(requested)
        guard bpm > 0, maxHz > 0 else { return snapped }
        let beatsPerSecond = bpm / 60.0
        for step in BeatBinding.allowedSteps where step >= snapped {
            if beatsPerSecond / step <= maxHz { return step }
        }
        return BeatBinding.allowedSteps.last ?? snapped
    }

    /// The free-running flash-rate ceiling as a REAL clamp (Slice 2). The
    /// strobe/party speed curves used to stay under 3 Hz only by arithmetic
    /// coincidence (0.5 + speed/100 × 2.5 tops out at 3.0) — a widened
    /// catalog range would have silently raised the ceiling. Every
    /// flash-class free-run Hz now passes through here; no exact typed
    /// value, adaptive drag, or range change can bypass it (spec §24).
    enum FlashSafety {
        static let maxFlashHz = 3.0
        static func clampedHz(_ hz: Double) -> Double {
            min(maxFlashHz, max(0, hz))
        }
    }

    /// Continuous cycle position: whole part = cycle index, fraction = phase.
    private static func cyclePosition(at t: Double, snapshot: BeatSnapshot,
                                      beatsPerCycle: Double, phaseOffsetBeats: Double) -> Double {
        let beatsElapsed = (t - snapshot.beatEpoch) / snapshot.beatInterval
        return (beatsElapsed - phaseOffsetBeats) / max(beatsPerCycle, 0.001)
    }

    /// 0..<1 position within the current cycle. Requires snapshot.bpm > 0.
    static func cyclePhase(at t: Double, snapshot: BeatSnapshot,
                           beatsPerCycle: Double, phaseOffsetBeats: Double = 0) -> Double {
        guard snapshot.bpm > 0 else { return 0 }
        let pos = cyclePosition(at: t, snapshot: snapshot,
                                beatsPerCycle: beatsPerCycle, phaseOffsetBeats: phaseOffsetBeats)
        let frac = pos - floor(pos)
        return frac < 0 ? frac + 1 : frac
    }

    /// Whole cycles elapsed since the (offset) epoch — negative before it.
    /// Loops fire once per index change instead of counting ticks.
    static func cycleIndex(at t: Double, snapshot: BeatSnapshot,
                           beatsPerCycle: Double, phaseOffsetBeats: Double = 0) -> Int {
        guard snapshot.bpm > 0 else { return 0 }
        return Int(floor(cyclePosition(at: t, snapshot: snapshot,
                                       beatsPerCycle: beatsPerCycle,
                                       phaseOffsetBeats: phaseOffsetBeats)))
    }

    /// Host time of the next cycle boundary strictly after `t` — what REST
    /// loops sleep toward for bar-level sync. Requires snapshot.bpm > 0.
    static func nextCycleBoundary(after t: Double, snapshot: BeatSnapshot,
                                  beatsPerCycle: Double, phaseOffsetBeats: Double = 0) -> Double {
        guard snapshot.bpm > 0 else { return t }
        let idx = floor(cyclePosition(at: t, snapshot: snapshot,
                                      beatsPerCycle: beatsPerCycle,
                                      phaseOffsetBeats: phaseOffsetBeats))
        let nextPos = idx + 1
        return snapshot.beatEpoch
            + (nextPos * max(beatsPerCycle, 0.001) + phaseOffsetBeats) * snapshot.beatInterval
    }

    /// Convenience: nil when free-running, else the binding's cycle phase.
    static func cyclePhase(_ binding: BeatBinding, snapshot: BeatSnapshot, at t: Double) -> Double? {
        guard !isFreeRunning(binding, snapshot: snapshot) else { return nil }
        return cyclePhase(at: t, snapshot: snapshot,
                          beatsPerCycle: binding.beatsPerCycle,
                          phaseOffsetBeats: binding.phaseOffsetBeats)
    }
}

// MARK: - Live-clock helpers (loop side)

extension BeatMath {

    /// Per-tick lock check for effect loops: non-nil only when the binding
    /// is active AND the shared clock is running right now. The returned
    /// beatsPerCycle is already rate-capped (maxHz defaults to the WCAG
    /// 3 Hz flash limit; REST loops pass their cadence floor instead,
    /// e.g. 1.0/0.9 for the 900 ms grouped-light cadence).
    static func liveLock(_ binding: BeatBinding,
                         maxHz: Double = 3.0) -> (snapshot: BeatSnapshot, beatsPerCycle: Double)? {
        guard binding.isActive else { return nil }
        let snap = BeatClock.snapshot()
        guard snap.bpm > 0 else { return nil }
        return (snap, wcagSafeBeatsPerCycle(requested: binding.beatsPerCycle,
                                            bpm: snap.bpm, maxHz: maxHz))
    }

    /// Chunked sleep to the next cycle boundary. Re-derives from the live
    /// clock every ≤250 ms, so tempo changes, taps, and nudges retarget the
    /// boundary mid-wait — the loop never accumulates phase. Returns
    /// immediately if the clock disappears; throws on cancellation.
    static func sleepUntilNextCycle(beatsPerCycle: Double,
                                    phaseOffsetBeats: Double = 0) async throws {
        let first = BeatClock.snapshot()
        guard first.bpm > 0 else { return }
        let startIndex = cycleIndex(at: CACurrentMediaTime(), snapshot: first,
                                    beatsPerCycle: beatsPerCycle,
                                    phaseOffsetBeats: phaseOffsetBeats)
        while !Task.isCancelled {
            let snap = BeatClock.snapshot()
            guard snap.bpm > 0 else { return }
            let now = CACurrentMediaTime()
            if cycleIndex(at: now, snapshot: snap, beatsPerCycle: beatsPerCycle,
                          phaseOffsetBeats: phaseOffsetBeats) != startIndex { return }
            let boundary = nextCycleBoundary(after: now, snapshot: snap,
                                             beatsPerCycle: beatsPerCycle,
                                             phaseOffsetBeats: phaseOffsetBeats)
            let chunk = max(0.002, min(boundary - now, 0.25))
            try await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
        }
    }
}

// MARK: - BeatBindingBox

/// Thread-safe live holder so a RUNNING loop sees beat-binding edits
/// immediately (mirrors the StudioParamBox pattern — the loop captures the
/// reference, the UI writes the value). Effects-tab loops read `.value`
/// once per iteration.
final class BeatBindingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: BeatBinding

    init(_ value: BeatBinding = .off) { _value = value }

    var value: BeatBinding {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - Studio param-box bridge

extension BeatBinding {
    /// Studio surfaces persist the binding as plain Doubles inside the live
    /// param box so slider-style plumbing keeps working unchanged.
    static let studioModeKey = "beat_mode"
    static let studioPerCycleKey = "beat_per_cycle"
    static let studioPhaseKey = "beat_phase"

    static func fromStudioValues(_ p: [String: Double]) -> BeatBinding {
        BeatBinding(mode: (p[studioModeKey] ?? 0) > 0.5 ? .beatLocked : .off,
                    beatsPerCycle: p[studioPerCycleKey] ?? 1,
                    phaseOffsetBeats: p[studioPhaseKey] ?? 0)
    }

    var studioValues: [String: Double] {
        [Self.studioModeKey: isActive ? 1 : 0,
         Self.studioPerCycleKey: beatsPerCycle,
         Self.studioPhaseKey: phaseOffsetBeats]
    }
}
