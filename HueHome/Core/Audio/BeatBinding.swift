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

        /// How far the RENDERED **relative luminance** may climb above the
        /// luminance trough before the climb is a flash ONSET: 0.10 — WCAG
        /// 2.3.1's general-flash threshold, in the unit WCAG states it in
        /// (10 % of maximum relative luminance).
        ///
        /// Two separate defects live in the history of this constant.
        ///
        /// It was once `flashRiseEpsilon` (2 %), a per-FRAME slew limit wearing a
        /// flash threshold's name: comparing each frame only with the frame
        /// before it means any ramp climbing less than the epsilon per frame is
        /// never a candidate at all, and at 50 fps a 0.019/frame ramp is 0.95 of
        /// full scale per second (defect M3). The comparison is against
        /// `luminanceTroughSinceOnset` — the LOWEST luminance emitted since the
        /// last admitted onset — so the question is "how far has the light
        /// climbed since it was last dark", not "how fast is it climbing this
        /// frame".
        ///
        /// It was then applied to **Hue dimming**, which is not luminance at all
        /// (third pass, H-1/H-2/M-3). Hue's `brightness` is a perceptual L*-like
        /// dimming level; luminance is roughly its cube. 0.901 → 1.000 dimming is
        /// a 0.099 dimming step — under a 0.10 dimming threshold — but a 0.235
        /// step in relative luminance, more than twice the WCAG limit. And a
        /// dimming rule is blind to chromaticity: saturated blue at dimming 0.90
        /// is 5 % of maximum luminance while white at dimming 0.85 is 66 %, so a
        /// blue → white step at *falling* dimming is a two-thirds-of-full-scale
        /// luminance RISE that a dimming rule reads as a decay. Candidacy is now
        /// measured in `WireFrame.relativeLuminance` and nothing else.
        static let onsetRiseThreshold = 0.10

        /// How far a frame's chromaticity must move (CIE xy Euclidean distance)
        /// for the move to be a palette STEP rather than tint drift. Two orders
        /// of magnitude below any step Party renders (its closest palette pair is
        /// 0.13 apart) and an order above the per-frame wobble a live tint slider
        /// produces, so it separates the two without a per-effect special case.
        ///
        /// A chroma step is NOT itself an onset any more. Chromaticity governs
        /// exactly one rule — the WCAG red flash below — because every other
        /// perceptible palette change is already a luminance change and the
        /// luminance rule sees it.
        static let onsetColorDelta = 0.02

        /// WCAG 2.3.1's *red flash* is the one flash a general-luminance rule
        /// cannot express: a transition to or from **saturated red** is hazardous
        /// at luminance changes far below the 10 % general threshold. This is
        /// that carve-out, kept as small as it can be: a chromaticity step whose
        /// source or destination is saturated red is a candidate at any luminance
        /// change of at least 0.02.
        ///
        /// Every other chromaticity step is governed purely by the luminance
        /// rule. A blue → white step at equal dimming is a luminance RISE and is
        /// caught there; white → blue is a fall and passes, exactly as a dimming
        /// fall does.
        static let redFlashLuminanceDelta = 0.02

        /// "Saturated red" for the rule above: at least 80 % of the frame's
        /// linear-RGB drive is in the red channel. Hue's red primary (0.64, 0.33)
        /// scores 1.0; D65 white scores 0.33.
        static let saturatedRedFraction = 0.8

        // ── Relative luminance (the unit the rules are stated in) ───

        /// CIE L* → Y, the cube approximation: `Y = ((100·bri + 16) / 116)³`.
        ///
        /// Hue's `brightness` (0…1 here, 0…100 on the wire) is a *perceptual*
        /// dimming level, near-linear in CIE L*, not in luminance. Treating it as
        /// luminance overstates every dark step and understates every bright one
        /// — which is exactly how a 0.099 dimming step at the top of the range
        /// (0.901 → 1.000) hid a 0.235 luminance flash. Clamped into 0…1, and
        /// exactly 0 at dimming 0 so "off" is off rather than the 0.0026 the
        /// cube's offset would otherwise leave. Total: a non-finite input is 0.
        static func dimmingLuminance(_ brightness: Double) -> Double {
            guard brightness.isFinite, brightness > 0 else { return 0 }
            let l = min(max(brightness, 0), 1)
            let v = (100.0 * l + 16.0) / 116.0
            return min(1, max(0, v * v * v))
        }

        /// CIE xy → linear **sRGB** drive, normalized so the largest channel is
        /// 1.0 — i.e. the colour as the fixture actually renders it at full
        /// drive, which is what a bridge does with an xy request.
        ///
        /// sRGB primaries (not Hue's gamut C) on purpose: the 0.2126/0.7152/0.0722
        /// coefficients that turn this into a luminance are sRGB's, so the pair is
        /// self-consistent and a saturated primary lands exactly on its own
        /// coefficient. Out-of-sRGB-gamut coordinates (Hue's gamut is wider —
        /// Party's green (0.17, 0.70) is outside it) clamp their negative channels
        /// to 0, which is what the bridge's own gamut mapping does with them.
        /// Total: a degenerate y ≤ 0 resolves to black rather than dividing by 0.
        static func linearRGB(x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
            guard x.isFinite, y.isFinite, y > 0 else { return (0, 0, 0) }
            let bigX = x / y
            let bigZ = (1.0 - x - y) / y
            var r =  3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
            var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
            var b =  0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
            r = max(r, 0); g = max(g, 0); b = max(b, 0)
            let peak = max(r, max(g, b))
            guard peak > 0, peak.isFinite else { return (0, 0, 0) }
            return (r / peak, g / peak, b / peak)
        }

        /// Relative luminance of a chromaticity at FULL drive: white ≈ 1.00,
        /// green ≈ 0.72, yellow ≈ 0.54, red ≈ 0.21, blue ≈ 0.07. This is the
        /// factor the dimming luminance is scaled by, and it is the whole reason
        /// a blue flash and a white flash are not the same flash.
        static func chromaticityLuminanceFactor(x: Double, y: Double) -> Double {
            let c = linearRGB(x: x, y: y)
            return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }

        /// Fraction of the linear drive that is red — the red-flash test's input.
        static func redDriveFraction(x: Double, y: Double) -> Double {
            let c = linearRGB(x: x, y: y)
            let sum = c.r + c.g + c.b
            guard sum > 0 else { return 0 }
            return c.r / sum
        }

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
        /// One frame exactly as it reaches the wire: the CIE xy and the
        /// brightness a loop asked to stream.
        ///
        /// The gate measures onsets on THESE, because the frame is what a
        /// photosensitive viewer perceives. A loop's own notion of an onset — a
        /// duty edge, a cycle-index change, a palette step — is a statement about
        /// what the loop COMPUTED, and a loop puts frames on the wire that none of
        /// those describe: gate hold frames, afterglow frames, ambient frames, the
        /// first frame of a brand-new run. Every one of those is a real light
        /// level, and every one of them used to escape the gate.
        struct WireFrame: Equatable {
            let x: Double
            let y: Double
            let brightness: Double

            /// Total: a non-finite coordinate resolves to D65 white and a
            /// non-finite brightness to 0, so a corrupt param box can neither
            /// trap here nor poison the trough with a NaN (every NaN comparison
            /// is false, so a NaN trough would answer "not a rise" forever).
            init(x: Double, y: Double, brightness: Double) {
                self.x = x.isFinite ? x : 0.3127
                self.y = y.isFinite ? y : 0.3290
                self.brightness = brightness.isFinite ? min(max(brightness, 0), 1) : 0
            }

            /// CIE xy Euclidean distance — the palette-step measure.
            func chromaDistance(to other: WireFrame) -> Double {
                let dx = x - other.x, dy = y - other.y
                return (dx * dx + dy * dy).squareRoot()
            }

            /// **What a viewer's eye receives**, 0…1 of maximum: the frame's
            /// chromaticity luminance factor times its dimming luminance.
            ///
            /// This is the quantity every candidacy rule is stated in. It is not
            /// `brightness`: `brightness` is a perceptual dimming level, and a
            /// chromaticity carries between 7 % (saturated blue) and 100 %
            /// (white) of maximum luminance at the same dimming.
            var relativeLuminance: Double {
                FlashSafety.chromaticityLuminanceFactor(x: x, y: y)
                    * FlashSafety.dimmingLuminance(brightness)
            }

            /// WCAG's red-flash subject: ≥ `saturatedRedFraction` of the linear
            /// drive is red.
            var isSaturatedRed: Bool {
                FlashSafety.redDriveFraction(x: x, y: y)
                    >= FlashSafety.saturatedRedFraction - FlashSafety.onsetComparisonTolerance
            }
        }

        /// What the caller must put on the wire for the frame it asked for.
        ///
        /// `.hold` carries the LAST EMITTED frame — colour AND brightness — so a
        /// refusal repeats exactly what the bridge is already showing. The old
        /// hold frame was assembled by the caller from `lastBri ?? minBri`, and on
        /// a loop's first gate `lastBri` was nil: after a run at min 0 was replaced
        /// by a run at min_brightness 50, the very frame streamed to REFUSE an
        /// onset was itself an ungated rise to 0.50 (blocker B1). A hold frame can
        /// never be a rise if it is the frame that is already on the wire.
        enum FrameVerdict: Equatable {
            /// Stream the requested frame — it is not a candidate, or the ledger
            /// admitted it.
            case emit(WireFrame)
            /// Stream this instead and ask again next frame. A refusal is a
            /// DELAY, never a skip.
            case hold(WireFrame)

            /// The frame to send. The only value a caller needs.
            var frame: WireFrame {
                switch self {
                case .emit(let f), .hold(let f): return f
                }
            }

            var wasAdmitted: Bool {
                if case .emit = self { return true }
                return false
            }
        }

        /// What one `admit` decided, and everything `commit` needs to make that
        /// decision true — or to undo it if the frame never reached the wire.
        ///
        /// A caller may not act on the verdict and then forget: `admit` records
        /// the frame PROVISIONALLY (so a second loop instance sharing the ledger
        /// during the un-awaited cancel window never sees a state the wire is not
        /// in), and `commit` is what turns the provisional record into a fact or
        /// rolls it back. Every `admit` must be followed by exactly one `commit`.
        struct Reservation {
            /// What the caller must put on the wire.
            let verdict: FrameVerdict
            /// The lastOnset value this admit installed, if it stamped one.
            fileprivate let stampedAt: Double?
            /// The lastOnset value before this admit — the rollback target.
            fileprivate let priorLastOnset: Double?
            /// Serial number of this admit, so a rollback can tell whether any
            /// other frame has touched the gate since.
            fileprivate let sequence: UInt64

            var frame: WireFrame { verdict.frame }
            var wasAdmitted: Bool { verdict.wasAdmitted }
        }

        struct OnsetGate {
            private(set) var lastOnset: Double?

            /// The last frame this gate put on the wire. `nil` before the very
            /// first frame of a bridge's life **and** whenever the wire state has
            /// become unknown — a send the transport refused, which is what a
            /// reconnect looks like from here.
            private(set) var lastEmitted: WireFrame?

            /// The LOWEST **relative luminance** EMITTED since the last admitted
            /// onset — the floor a rise is measured from, reset to the emitted
            /// level at each admission. Tracking the trough (rather than the
            /// previous frame) is what makes a slow cumulative ramp a candidate:
            /// the ramp is judged against where the light last was, not against
            /// where it was 20 ms ago.
            private(set) var luminanceTroughSinceOnset: Double

            private var sequence: UInt64 = 0

            init(lastOnset: Double? = nil, lastEmitted: WireFrame? = nil) {
                self.lastOnset = lastOnset
                self.lastEmitted = lastEmitted
                self.luminanceTroughSinceOnset = lastEmitted?.relativeLuminance ?? 0
            }

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

            /// Is this frame an onset CANDIDATE against the wire state?
            ///
            /// Two ways in, and only two — both stated in RELATIVE LUMINANCE,
            /// which is what a photosensitive viewer's eye integrates:
            ///
            ///  1. **A rise from the luminance trough** of at least
            ///     `onsetRiseThreshold` (WCAG 2.3.1's general flash: 10 % of
            ///     maximum relative luminance). Measured against the lowest
            ///     luminance emitted since the last admitted onset, so it catches
            ///     the frame-to-frame jump AND the ramp that accumulates the same
            ///     climb over twenty frames. Because it is luminance and not
            ///     dimming, it also catches the two things a dimming rule missed:
            ///     the top-of-range dimming step (0.901 → 1.000 is 0.235 of
            ///     maximum luminance) and the chromaticity step that raises
            ///     luminance while dimming falls (blue at 0.90 → white at 0.85 is
            ///     a 0.66 rise).
            ///  2. **A WCAG red flash**: a chromaticity step (further than
            ///     `onsetColorDelta`) to or from saturated red, with a luminance
            ///     change of at least `redFlashLuminanceDelta` in EITHER
            ///     direction. This is the only rule chromaticity has of its own,
            ///     and it exists because red flashes are hazardous well below the
            ///     general threshold.
            ///
            /// There is deliberately no "palette step" rule beyond that, and no
            /// `lastAdmittedBrightness` exemption to carve back out of one. Under
            /// a dimming rule a palette step at constant dimming was invisible, so
            /// chromaticity needed its own onset rule — and that rule then called
            /// the storm's white afterglow → blue ambient step an onset, which
            /// needed an exemption, which needed the level it was measured
            /// against. In luminance none of that machinery is required: Party's
            /// palette steps at constant dimming ARE luminance steps (blue 0.07 →
            /// green 0.72 of maximum) and rule 1 sees the rises; the storm's
            /// afterglow → ambient step is a luminance FALL and rule 1 correctly
            /// ignores it.
            func isOnsetCandidate(_ frame: WireFrame) -> Bool {
                guard let last = lastEmitted else { return false }
                let tol = FlashSafety.onsetComparisonTolerance
                let luminance = frame.relativeLuminance
                if luminance - luminanceTroughSinceOnset
                    >= FlashSafety.onsetRiseThreshold - tol { return true }
                guard frame.chromaDistance(to: last) > FlashSafety.onsetColorDelta,
                      frame.isSaturatedRed || last.isSaturatedRed
                else { return false }
                return abs(luminance - last.relativeLuminance)
                    >= FlashSafety.redFlashLuminanceDelta - tol
            }

            /// The frame-level gate, **reserve half**: what should go on the wire
            /// for `frame`, and what `commit` will have to do about it?
            ///
            /// Non-candidates (falls, sub-threshold rises, unchanged frames) pass
            /// straight through and update the wire state. A candidate is admitted
            /// only if `tryOnset` allows it; otherwise the verdict is `.hold` of
            /// the last emitted frame and nothing moves — the trough and the wire
            /// state are already correct, because the frame being re-sent is the
            /// one that set them.
            ///
            /// **The first frame after the wire state became unknown** — the very
            /// first frame of a bridge's life, or the first frame after a send the
            /// transport refused — splits on whether this ledger has ever stamped
            /// an onset:
            ///
            ///  • **No prior stamp (a cold ledger).** The frame is emitted
            ///    unconditionally: refusing it would mean streaming nothing, and a
            ///    paused DTLS stream lets the bridge fall back to its own light
            ///    state mid-effect. It is STAMPED if its luminance is at or above
            ///    the threshold — the prior wire state is unknown and the
            ///    conservative reading of "unknown" is black, which makes a 0.76
            ///    first frame a 0.76 rise. That costs at most one 0.34 s delay at
            ///    the very first frame of a bridge's life, and closes the hole the
            ///    alternative leaves: a two-frame run followed by a card switch
            ///    would otherwise realize its first MEASURED rise 0.06 s after its
            ///    first emitted peak. A first frame below the threshold (the
            ///    storm's 0.05 ambient) is not stamped, so the first strike of a
            ///    session is never delayed.
            ///
            ///  • **A prior stamp exists.** There IS a realized onset to be too
            ///    close to, so a bright first frame is a candidate subject to the
            ///    time gate — this is the reconnect case (blocker B-1): the wire
            ///    went away mid-hold at 0.05 and comes back wanting 0.90, which on
            ///    the wire is a full-scale rise however the ledger got here. When
            ///    the gate refuses, the hold frame cannot be "the last emitted
            ///    frame" — there isn't one — so it is **black at the requested
            ///    chromaticity**. A fall is always safe, and streaming it keeps
            ///    the DTLS stream alive, which is the one thing a refusal may
            ///    never trade away.
            mutating func admit(frame: WireFrame, at t: Double,
                                minPeriod: Double = FlashSafety.minOnsetLedgerPeriod) -> Reservation {
                sequence &+= 1
                let prior = lastOnset
                let tol = FlashSafety.onsetComparisonTolerance

                guard let last = lastEmitted else {
                    let bright = frame.relativeLuminance
                        >= FlashSafety.onsetRiseThreshold - tol
                    guard bright else {
                        record(frame, resettingTrough: true)
                        return reservation(.emit(frame), stampedAt: nil, prior: prior)
                    }
                    if prior == nil {
                        let stamped = tryOnset(at: t, minPeriod: minPeriod)
                        record(frame, resettingTrough: true)
                        return reservation(.emit(frame),
                                           stampedAt: stamped ? lastOnset : nil, prior: prior)
                    }
                    guard tryOnset(at: t, minPeriod: minPeriod) else {
                        let black = WireFrame(x: frame.x, y: frame.y, brightness: 0)
                        record(black, resettingTrough: true)
                        return reservation(.hold(black), stampedAt: nil, prior: prior)
                    }
                    record(frame, resettingTrough: true)
                    return reservation(.emit(frame), stampedAt: lastOnset, prior: prior)
                }

                guard isOnsetCandidate(frame) else {
                    record(frame, resettingTrough: false)
                    return reservation(.emit(frame), stampedAt: nil, prior: prior)
                }
                guard tryOnset(at: t, minPeriod: minPeriod) else {
                    return reservation(.hold(last), stampedAt: nil, prior: prior)
                }
                record(frame, resettingTrough: true)
                return reservation(.emit(frame), stampedAt: lastOnset, prior: prior)
            }

            /// The frame-level gate, **commit half**: reconcile the ledger with
            /// what the transport actually did with the frame `admit` handed the
            /// caller.
            ///
            /// Two things happen here that cannot happen in `admit`.
            ///
            /// **Delivery re-stamps at the delivery time.** `admit` decides with a
            /// clock sample taken BEFORE the send and stamps that sample; the
            /// frame reaches the transport some tens of milliseconds later, after
            /// an actor hop and whatever main-actor jitter is going on. A reference
            /// point set at decision time therefore permits a realized spacing
            /// shorter than the period it enforces (defect H-3, worth more than
            /// the 6.67 ms the whole `minOnsetLedgerPeriod` argument was about).
            /// Moving the stamp forward to `deliveredAt` fixes the reference to
            /// the wire. Deciding on the earlier sample stays conservative in the
            /// right direction: `t − lastOnset ≥ period` implies
            /// `deliveredAt − lastOnset ≥ period`, never the reverse.
            ///
            /// **A refused send un-does the reservation and forgets the wire.**
            /// `send(channels:)` is fire-and-forget and silently drops every frame
            /// while the DTLS connection is re-establishing. The ledger used to
            /// run ahead of the wire there: it recorded 0.90 as emitted, and when
            /// the stream came back the first delivered frame was a full-scale
            /// rise that the ledger's model said was not a candidate at all
            /// (blocker B-1). A dropped frame changed no light, so the stamp is
            /// rolled back (only if nothing else has touched the gate since — the
            /// reference point may never move backwards past another loop's real
            /// onset), and the wire state is dropped to `nil`: whatever the bridge
            /// is showing after a reconnect is not knowable from here, so the next
            /// delivered frame is measured as a first frame.
            mutating func commit(_ reservation: Reservation, delivered: Bool,
                                 at deliveredAt: Double) {
                guard delivered else {
                    if sequence == reservation.sequence,
                       let stamped = reservation.stampedAt, lastOnset == stamped {
                        lastOnset = reservation.priorLastOnset
                    }
                    forgetWire()
                    return
                }
                guard let stamped = reservation.stampedAt, lastOnset == stamped,
                      deliveredAt.isFinite, deliveredAt > stamped else { return }
                lastOnset = deliveredAt
            }

            /// The wire state is unknown from here on. Not a reset: `lastOnset`
            /// (what was realized, and when) survives — it is the only thing that
            /// still applies after a reconnect.
            mutating func forgetWire() {
                lastEmitted = nil
                luminanceTroughSinceOnset = 0
            }

            private func reservation(_ verdict: FrameVerdict, stampedAt: Double?,
                                     prior: Double?) -> Reservation {
                Reservation(verdict: verdict, stampedAt: stampedAt,
                            priorLastOnset: prior, sequence: sequence)
            }

            /// Records what was handed to the transport. An admission re-bases the
            /// trough to the emitted luminance (a further climb above the peak
            /// just admitted is a NEW onset); anything else lowers it if the frame
            /// is darker than the darkest frame so far.
            private mutating func record(_ frame: WireFrame, resettingTrough: Bool) {
                lastEmitted = frame
                let luminance = frame.relativeLuminance
                luminanceTroughSinceOnset = resettingTrough
                    ? luminance
                    : min(luminanceTroughSinceOnset, luminance)
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

            /// The last frame this bridge put on the wire.
            var lastEmitted: WireFrame? {
                lock.lock(); defer { lock.unlock() }
                return gate.lastEmitted
            }

            /// The lowest relative luminance emitted since the last admitted onset.
            var luminanceTroughSinceOnset: Double {
                lock.lock(); defer { lock.unlock() }
                return gate.luminanceTroughSinceOnset
            }

            func tryOnset(at t: Double,
                          minPeriod: Double = FlashSafety.minOnsetLedgerPeriod) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return gate.tryOnset(at: t, minPeriod: minPeriod)
            }

            /// Decide AND provisionally record in one critical section. Two calls
            /// (ask, then note what was sent) would leave a window in which the
            /// other loop instance alive during the un-awaited cancel window could
            /// interleave its own frame between them, and the trough this gate
            /// measures rises from would then belong to neither loop. The record
            /// is provisional precisely so it can be conservative while the send
            /// is still in flight; `commit` settles it.
            func admit(frame: WireFrame, at t: Double,
                       minPeriod: Double = FlashSafety.minOnsetLedgerPeriod) -> Reservation {
                lock.lock(); defer { lock.unlock() }
                return gate.admit(frame: frame, at: t, minPeriod: minPeriod)
            }

            /// Settle a reservation against what the transport did with it. Every
            /// `admit` must be followed by exactly one of these.
            func commit(_ reservation: Reservation, delivered: Bool, at deliveredAt: Double) {
                lock.lock(); defer { lock.unlock() }
                gate.commit(reservation, delivered: delivered, at: deliveredAt)
            }

            /// Drop the wire state without touching the realized-onset clock —
            /// what a caller does when it learns the bridge is showing something
            /// this ledger did not put there.
            func forgetWire() {
                lock.lock(); defer { lock.unlock() }
                gate.forgetWire()
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
