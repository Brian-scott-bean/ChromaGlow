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
//    On the 20 ms Entertainment grid the cap is stated in FRAMES, not Hz:
//    ENT loops pass FlashSafety.entertainmentMaxLockHz and plan whole safe
//    cycles through FlashSafety, because a requested rate under 3 Hz says
//    nothing about the rate the grid actually realizes.

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
        // Finite-guarded exactly like `snappedStep`: a NaN offset survives the
        // min/max clamp untouched (every comparison against NaN is false), and
        // `BeatMath.cycleIndex` would then evaluate `Int(floor(.nan))` — a trap,
        // not a wrong colour. Persisted values can be hand-edited or corrupt, so
        // the invalid case resolves to "no offset" instead of crashing the loop.
        self.phaseOffsetBeats = phaseOffsetBeats.isFinite
            ? min(max(phaseOffsetBeats, Self.phaseOffsetRange.lowerBound),
                  Self.phaseOffsetRange.upperBound)
            : 0
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

    /// The free-running flash-rate ceiling as a REAL clamp (Slice 2), and the
    /// frame-realizable safety math every flash-class Entertainment loop plans
    /// with (Slice 2 remediation, R1).
    ///
    /// The strobe/party speed curves used to stay under 3 Hz only by arithmetic
    /// coincidence (0.5 + speed/100 × 2.5 tops out at 3.0) — a widened catalog
    /// range would have silently raised the ceiling. Worse, a *requested* Hz
    /// under 3 says nothing about the *realized* rate: the loops floored each
    /// half-cycle onto the 20 ms DTLS grid independently, so speed 100 rendered
    /// 15–16 frames (3.13–3.33 Hz) and Thunderstorm rendered 9 + 1 = 10 frames
    /// (5.0 Hz). The invariant is therefore stated in FRAMES, not in Hz:
    ///
    ///   **Realized onset-to-onset spacing ≥ `minCycleFrames()` (17) frames
    ///   = 0.34 s on the 20 ms Entertainment grid, on every legal path.**
    ///
    /// Everything here is pure and total — no clock, no I/O, and no input
    /// (including 0, negative, NaN and infinity) can make it trap. Loops plan
    /// a whole SAFE TOTAL first and split it; they never floor two halves
    /// independently, and they never sleep a hard-coded frame literal.
    enum FlashSafety {
        static let maxFlashHz = 3.0
        static func clampedHz(_ hz: Double) -> Double {
            min(maxFlashHz, max(0, hz))
        }

        // ── The Entertainment render grid ───────────────────────────

        /// One DTLS frame = 20 ms (50 fps). Every ENT flash loop's time
        /// quantum: nothing can be realized at a finer resolution than this.
        static let entertainmentFrameDuration = 0.02

        /// What ENT loops pass to `Task.sleep` — never a `20_000_000` literal,
        /// so the grid and the math can never drift apart (Guard 14).
        static var entertainmentFrameNanoseconds: UInt64 {
            UInt64(entertainmentFrameDuration * 1_000_000_000)
        }

        /// The WCAG rate expressed as a period (1/3 s). This is the *planning*
        /// constant — what `minCycleFrames` rounds UP from. It is deliberately
        /// NOT what the runtime ledger enforces: 1/3 s is not realizable on the
        /// 20 ms grid, so the gate uses `minOnsetLedgerPeriod` (0.34 s) instead.
        static let minOnsetPeriod = 1.0 / maxFlashHz

        /// Planning floor for a requested rate. The catalog's slowest flash
        /// speed is 0.5 Hz; this is well under it and exists only so a
        /// degenerate request (0, −1, −inf) plans a finite cycle instead of
        /// trapping on an Int conversion.
        static let slowestPlannedHz = 0.1

        /// Frames that `minOnsetPeriod` occupies on the given grid, rounded UP
        /// — 17 on the 20 ms grid (0.34 s), because 16 frames is 0.32 s and
        /// 0.32 s < 1/3 s. This is the invariant's unit.
        static func minCycleFrames(frameDuration: Double = entertainmentFrameDuration) -> Int {
            let fd = usableFrameDuration(frameDuration)
            return max(1, Int((minOnsetPeriod / fd - 1e-9).rounded(.up)))
        }

        /// The fastest beat-lock rate that is REALIZABLE on the frame grid:
        /// 1 / (17 × 0.02) = 2.9412 Hz.
        ///
        /// This is not a product preference — it is an implementation
        /// consequence of the ≥ 17-frame realized-onset invariant. A 3.0 Hz
        /// lock has a 333.3 ms period, which the 20 ms grid can only render as
        /// 16 frames (0.32 s — unsafe) or 17 frames (0.34 s — safe but 6.7 ms
        /// slow every cycle, i.e. unbounded lag against the beat). With a
        /// period ≥ 340 ms, quantization alone can never produce fewer than 17
        /// frames, so the lock stays honest AND safe. Cost: three 3.5-BPM
        /// bands step to the next beat division (spec §24).
        static var entertainmentMaxLockHz: Double {
            1.0 / (Double(minCycleFrames()) * entertainmentFrameDuration)
        }

        /// What the runtime ledger actually enforces: the invariant's OWN unit,
        /// `minCycleFrames` × the frame duration = **0.34 s** — not `minOnsetPeriod`
        /// (1/3 s).
        ///
        /// The two differ by 6.67 ms, and that gap used to be real slack in the
        /// only place that could not afford any. Within one run the frame plans
        /// already guarantee ≥ 17 frames, so the 6.67 ms was never consumed. The
        /// CROSS-run path has no plan behind it — a card switch, a stop/start or a
        /// session re-establishment starts a loop whose very first frame wants to
        /// flash, and the ledger is the *only* thing standing there. Worse, the
        /// ledger stamps the moment an onset is ADMITTED, not the moment the frame
        /// reaches the wire: an actor hop plus main-actor jitter can push the
        /// emission tens of milliseconds past the stamp. A period stated at 1/3 s
        /// therefore permits a realized 0.333 s − and, with jitter, a realized
        /// spacing that is short at BOTH ends. Stating the period in the same
        /// frames the invariant is stated in removes the discrepancy entirely.
        static var minOnsetLedgerPeriod: Double {
            Double(minCycleFrames()) * entertainmentFrameDuration
        }

        /// IEEE rounding tolerance for the gate's interval comparison — **1 ns**,
        /// and nothing more.
        ///
        /// This is not safety slack. `Double(n + 17) * 0.02 − Double(n) * 0.02`
        /// lands up to ~2 × 10⁻¹⁶ s BELOW `17 × 0.02` for a little over half of
        /// all grid positions, so a bare `<` would refuse arithmetically-exact
        /// 17-frame spacings and stall an extra frame every other cycle. At 1 ns
        /// the tolerance is seven orders of magnitude smaller than one frame: it
        /// can never admit a 16-frame (20 ms short) interval, which is the defect
        /// the gate exists to catch.
        static let onsetComparisonTolerance = 1e-9

        /// How far the rendered brightness may climb before the climb counts as a
        /// flash ONSET rather than a fade artefact (2% of full scale).
        ///
        /// A flash-class loop's onset is not "the cycle index changed" — it is
        /// "the light got brighter". Anything that moves the cycle phase BACKWARDS
        /// (a BeatClock epoch correction from `driveFromTrack`/`ingest`, which
        /// lands 1–2×/s while a track is playing; a phase nudge) or moves the
        /// hold/fade split FORWARD (dragging smoothness down) restores peak
        /// brightness inside the SAME cycle index. Gating the index alone lets
        /// that rise through ungated, and the genuine boundary milliseconds later
        /// is then admitted on top of it.
        static let flashRiseEpsilon = 0.02

        /// Finite-guarded `Int(_: Double)` for a value read out of a live param
        /// box. `Int(Double.nan)`, `Int(.infinity)` and `Int(1e300)` all TRAP —
        /// a param box holds whatever a slider, a decoded preset or a hand-edited
        /// JSON put there, so the conversion has to be total before any range
        /// clamp downstream gets a chance to run. Truncates toward zero, exactly
        /// like the `Int(_:)` it replaces.
        static func clampedInt(_ value: Double, default fallback: Int,
                               range: ClosedRange<Int>) -> Int {
            guard value.isFinite else {
                return min(max(fallback, range.lowerBound), range.upperBound)
            }
            let truncated = value < 0 ? value.rounded(.up) : value.rounded(.down)
            let clamped = min(max(truncated, Double(range.lowerBound)),
                              Double(range.upperBound))
            return Int(clamped)
        }

        // ── Whole-cycle planning ────────────────────────────────────

        /// Frames in one SAFE cycle at the requested rate. Safety first: the
        /// total is floored at `minCycleFrames` BEFORE any split, which is the
        /// whole difference from the old per-half `Int(duration / 0.02)`.
        /// Total, finite-guarded, never traps: NaN plans the fastest safe
        /// cycle, and anything outside `slowestPlannedHz ... maxFlashHz`
        /// (0 and negatives included) is clamped into it.
        static func cycleFrames(hz: Double,
                                frameDuration: Double = entertainmentFrameDuration) -> Int {
            let fd = usableFrameDuration(frameDuration)
            let requested = hz.isNaN ? maxFlashHz
                                     : min(max(hz, slowestPlannedHz), maxFlashHz)
            let planned = Int(((1.0 / requested) / fd - 1e-9).rounded(.up))
            return max(minCycleFrames(frameDuration: fd), planned)
        }

        /// Splits a planned cycle into two parts that each render at least one
        /// frame and together render the whole cycle — so the split can never
        /// shorten the safe total. `firstFraction` is clamped to 0…1 (NaN
        /// splits evenly); a total below 2 is raised to 2, because "two parts,
        /// each ≥ 1 frame" is not expressible in fewer.
        static func splitFrames(total: Int, firstFraction: Double) -> (first: Int, second: Int) {
            let safeTotal = max(2, total)
            let fraction = firstFraction.isFinite ? min(max(firstFraction, 0), 1) : 0.5
            let raw = Int((Double(safeTotal) * fraction).rounded())
            let first = min(max(raw, 1), safeTotal - 1)
            return (first, safeTotal - first)
        }

        private static func usableFrameDuration(_ frameDuration: Double) -> Double {
            (frameDuration.isFinite && frameDuration > 0) ? frameDuration
                                                          : entertainmentFrameDuration
        }

        // ── Wall-clock backstop ─────────────────────────────────────

        /// Pure decision half of the runtime gate: admits an onset only when
        /// at least `minPeriod` (0.34 s — `minOnsetLedgerPeriod`, the invariant's
        /// own frame-stated unit) has passed since the last admitted one.
        /// A refusal means DELAY (stream a hold frame and ask again), never
        /// "skip this flash" — skipping would change the look, delaying only
        /// moves it by ≤ one frame.
        struct OnsetGate {
            private(set) var lastOnset: Double?

            init(lastOnset: Double? = nil) { self.lastOnset = lastOnset }

            /// `t` is a monotonic host time (CACurrentMediaTime). A NaN/infinite
            /// time is refused outright — an unmeasurable interval is not a
            /// proven-safe one.
            ///
            /// A time BEFORE the last onset is refused too, and — critically —
            /// does NOT move the reference point. `CACurrentMediaTime()` is
            /// sampled by each caller *outside* this lock, so during the
            /// un-awaited cancel window two loop instances on one bridge can
            /// present their samples out of order. The old `t >= last` qualifier
            /// meant such an inversion fell straight through to `lastOnset = t`:
            /// the ledger admitted the onset AND re-based backwards, so the next
            /// onset was measured from a point in the past and could land well
            /// inside a frame of the one just realized. The ledger's reference
            /// point may only ever move forward.
            mutating func tryOnset(at t: Double,
                                   minPeriod: Double = FlashSafety.minOnsetLedgerPeriod) -> Bool {
                guard t.isFinite else { return false }
                let period = (minPeriod.isFinite && minPeriod > 0) ? minPeriod
                                                                   : FlashSafety.minOnsetLedgerPeriod
                if let last = lastOnset {
                    guard t >= last else { return false }
                    if t - last < period - FlashSafety.onsetComparisonTolerance { return false }
                }
                lastOnset = t
                return true
            }
        }

        /// Thread-safe, reference-typed ledger (mirrors `BeatBindingBox`): one
        /// per BRIDGE in the orchestrator, held across loop instances. Stopping
        /// a card and starting another, a session re-establishment, or a
        /// transport flip all reuse the same ledger, so two *different* loops
        /// can never realize two onsets less than 1/3 s apart on one bridge.
        final class OnsetLedger: @unchecked Sendable {
            private let lock = NSLock()
            private var gate: OnsetGate

            init(lastOnset: Double? = nil) { gate = OnsetGate(lastOnset: lastOnset) }

            var lastOnset: Double? {
                lock.lock(); defer { lock.unlock() }
                return gate.lastOnset
            }

            func tryOnset(at t: Double,
                          minPeriod: Double = FlashSafety.minOnsetLedgerPeriod) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return gate.tryOnset(at: t, minPeriod: minPeriod)
            }
        }

        // ── Per-effect free-run plans ───────────────────────────────

        /// Strobe's free-run cycle: ON frames then OFF frames, planned as one
        /// safe total. Legacy visual curve unchanged (speed 0…100 → 0.5…3 Hz,
        /// duty splits the period); only the quantization is fixed.
        struct StrobePlan: Equatable {
            let onFrames: Int
            let offFrames: Int
            var totalFrames: Int { onFrames + offFrames }

            /// Legacy speed→rate curve, clamped at both ends.
            static func hz(speed: Double) -> Double {
                let s = speed.isNaN ? 50 : min(max(speed, 0), 100)
                return clampedHz(0.5 + (s / 100.0) * 2.5)
            }

            static func make(speed: Double, dutyCycle: Double,
                             frameDuration: Double = entertainmentFrameDuration) -> StrobePlan {
                let total = cycleFrames(hz: hz(speed: speed), frameDuration: frameDuration)
                let split = splitFrames(total: total, firstFraction: dutyCycle)
                return StrobePlan(onFrames: split.first, offFrames: split.second)
            }
        }

        /// Party's free-run cycle: hold at peak, then fade to min. Same speed
        /// curve as Strobe; `smoothness` is the fade's share of the cycle.
        struct PartyPlan: Equatable {
            let holdFrames: Int
            let fadeFrames: Int
            var totalFrames: Int { holdFrames + fadeFrames }

            static func make(speed: Double, smoothness: Double,
                             frameDuration: Double = entertainmentFrameDuration) -> PartyPlan {
                let total = cycleFrames(hz: StrobePlan.hz(speed: speed), frameDuration: frameDuration)
                let split = splitFrames(total: total, firstFraction: 1.0 - smoothness)
                return PartyPlan(holdFrames: split.first, fadeFrames: split.second)
            }
        }

        /// Thunderstorm plans differently from Strobe/Party: its strikes are
        /// random in length and may be skipped entirely, so there is no fixed
        /// cycle to floor. Instead a `Budget` carries "frames since the last
        /// onset" across strikes, skipped strikes, and beat-alignment waits,
        /// and the ambient gap is stretched by whatever the budget still owes.
        enum ThunderstormPlan {
            /// The legacy gap curve, preserved bit-for-bit including its IEEE
            /// artefact: frequency 1.0 gives `2.0 − 1.8 = 0.19999999999999996`,
            /// and `Int(… / 0.02)` truncates 9.999999999999998 to **9** frames.
            /// Keeping it means the storm looks unchanged; the Budget — not
            /// this curve — is what makes it safe.
            static func requestedGapFrames(frequency: Double,
                                           frameDuration: Double = entertainmentFrameDuration) -> Int {
                let fd = usableFrameDuration(frameDuration)
                let f = frequency.isNaN ? 0.5 : min(max(frequency, 0), 1)
                let gapDuration = 2.0 - f * 1.8          // 0.2–2.0 seconds
                return max(5, Int(gapDuration / fd))
            }

            /// Legacy organic jitter: `max(1, length − 1) ... length + 2`.
            /// The catalog range is 1…8; the clamp only keeps a hand-edited or
            /// corrupt value from forming an invalid (empty) range.
            static func flashFrameRange(flashLength: Int) -> ClosedRange<Int> {
                let fl = min(max(flashLength, 1), 60)
                return max(1, fl - 1)...(fl + 2)
            }

            /// Legacy afterglow: 0 disables it outright, otherwise
            /// `base ... base + 1`.
            static func afterglowFrameRange(afterglow: Int) -> ClosedRange<Int> {
                let base = min(max(afterglow, 0), 60)
                return base == 0 ? 0...0 : base...(base + 1)
            }

            /// Frames rendered since the last strike's ONSET (its first flash
            /// frame). Starts saturated so the first strike of a session is
            /// never delayed, and saturates at the ceiling so it can neither
            /// overflow nor bank credit.
            struct Budget {
                private(set) var framesSinceOnset: Int
                private let ceilingFrames: Int

                init(frameDuration: Double = entertainmentFrameDuration) {
                    ceilingFrames = minCycleFrames(frameDuration: frameDuration)
                    framesSinceOnset = ceilingFrames
                }

                /// One (or n) non-flash frame rendered: an ambient gap frame, a
                /// beat-alignment wait frame, or a gate hold frame. All three
                /// count — they are real time on the wire.
                mutating func noteAmbient(frames: Int = 1) {
                    guard frames > 0 else { return }
                    framesSinceOnset = min(ceilingFrames,
                                           framesSinceOnset + min(frames, ceilingFrames))
                }

                /// A strike finished: the onset was `flashFrames + afterglowFrames`
                /// frames ago.
                mutating func noteStrike(flashFrames: Int, afterglowFrames: Int) {
                    let rendered = max(0, flashFrames) + max(0, afterglowFrames)
                    framesSinceOnset = min(ceilingFrames, rendered)
                }

                /// Ambient frames to render before the next strike opportunity:
                /// the legacy curve, stretched to whatever the invariant still
                /// owes. A skipped strike does not reset the budget, so skips
                /// only ever make the next spacing longer.
                func gapFrames(frequency: Double,
                               frameDuration: Double = entertainmentFrameDuration) -> Int {
                    max(requestedGapFrames(frequency: frequency, frameDuration: frameDuration),
                        ceilingFrames - framesSinceOnset)
                }
            }
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
    ///
    /// ⚠️ **UNCAPPED — never call this from a flash-class loop.** It uses the
    /// binding's RAW `beatsPerCycle`, so at 180 BPM × 1 beat it reports a
    /// 3 Hz cycle that the 20 ms Entertainment grid realizes as 16 frames
    /// (0.32 s) — below the photosensitivity floor. Flash-class loops must
    /// take their cycle from `liveLock(_:maxHz:)` with
    /// `FlashSafety.entertainmentMaxLockHz` and pass `lock.beatsPerCycle`
    /// into `cyclePhase(at:snapshot:beatsPerCycle:phaseOffsetBeats:)`.
    /// Kept only for tests and for non-flash callers that read a phase
    /// without driving light output. (`FlashSafetyTests` pins the 16-frame
    /// defect this signature would reintroduce.)
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
