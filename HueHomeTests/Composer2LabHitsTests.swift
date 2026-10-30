// Composer2LabHitsTests.swift
// HueHome Pro — Unit Tests (Play Along: hits that move across the room)
//
// A punch can travel: Roll sweeps each beat across the room and back and
// bursts the one out from the middle; Chase lands each beat on the next
// light. These tests time every light's hit against the beat, check that it
// follows where the lights actually sit, that no light is ever hit twice
// within the flash budget, that Dim Flashing Lights scales it, that the
// setting reaches the live look — and that, across every built-in look,
// moving hits lean on the flash shaper no more than whole-room hits do and
// never make the wire stutter.

import XCTest
@testable import HueHome

final class Composer2LabHitsTests: XCTestCase {

    private let epoch = 1000.0
    /// One evaluation step (2 ms): arrival times are good to one step.
    private let step = 0.002
    private var within: Double { step + 1e-6 }

    private func beat(_ bpm: Double, knowsTheOne: Bool = false) -> BeatSnapshot {
        BeatSnapshot(bpm: bpm, beatEpoch: epoch, beatsPerBar: 4, phaseConfidence: 1,
                     barConfidence: knowsTheOne ? 1 : 0)
    }

    /// A ring of lights around a room (the shape the theme tests use).
    private func ring(_ n: Int) -> Composer2SlotGeometry {
        guard n > 1 else { return .linear(count: n) }
        var points: [(x: Double, z: Double)] = []
        for i in 0..<n {
            let angle = Double(i) / Double(n) * 2 * .pi
            points.append((x: 0.5 + 0.45 * cos(angle), z: 0.5 + 0.3 * sin(angle)))
        }
        return Composer2SlotGeometry(points: points)
    }

    /// One steady white layer at 40 % that punches on the beat (or on heard hits).
    private func punchLook(_ travel: Composer2AudioModulation.Travel?,
                           source: Composer2AudioModulation.Source = .beat) -> Composer2Composition {
        var layer = Composer2Layer(name: "Hits", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.4))
        // A 0.15 s fade.
        layer.audio = Composer2AudioModulation(source: source, smoothing: 0, intensity: 0.8,
                                               punchDecay: (0.15 - 0.08) / 0.52, travel: travel)
        return Composer2Composition(name: "Hits", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
    }

    private struct Sample {
        let t: Double
        let bri: [Double]
    }

    /// Brightness per light every `step` seconds over [from, to).
    private func render(_ look: Composer2Composition, geometry: Composer2SlotGeometry, beat: BeatSnapshot,
                        from: Double, to: Double, eventCap: Double = 1,
                        heard: (Double) -> AudioFeatures = { _ in .silent }) -> [Sample] {
        var state = Composer2EngineState()
        var plans = Composer2Engine.plans(for: look, geometry: geometry)
        var frames: [Composer2Frame] = []
        var out: [Sample] = []
        let count = Int(((to - from) / step).rounded())
        for k in 0..<count {
            let t = from + Double(k) * step
            Composer2Engine.evaluate(look, time: t - epoch, geometry: geometry, plans: &plans, state: &state,
                                     audio: heard(t), beat: beat, hostNow: t, eventCap: eventCap, into: &frames)
            out.append(Sample(t: t, bri: frames.map(\.brightness)))
        }
        return out
    }

    /// The moment each light is brightest inside [from, to): a hit rises in
    /// one step, so that is when it arrived.
    private func arrivals(_ samples: [Sample], from: Double, to: Double) -> [Double] {
        let window = samples.filter { $0.t >= from - 1e-9 && $0.t < to - 1e-9 }
        let n = window.first?.bri.count ?? 0
        return (0..<n).map { i in
            var best = window[0]
            for s in window where s.bri[i] > best.bri[i] + 1e-12 { best = s }
            return best.t
        }
    }

    // MARK: - The model

    func testTravelIsOptionalAndLooksSavedBeforeItEncodeAsBefore() throws {
        let plain = Composer2AudioModulation(source: .beat)
        let data = try JSONEncoder().encode(plain)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["travel"], "a look without moving hits encodes exactly as before")
        XCTAssertNil(try JSONDecoder().decode(Composer2AudioModulation.self, from: data).travel)

        for travel in Composer2AudioModulation.Travel.allCases {
            var moving = plain
            moving.travel = travel
            XCTAssertEqual(try JSONDecoder().decode(Composer2AudioModulation.self, from: JSONEncoder().encode(moving)),
                           moving)
        }
        let unknown = Data(#"{"source":"beat","intensity":0.5,"travel":"teleport"}"#.utf8)
        let decoded = try JSONDecoder().decode(Composer2AudioModulation.self, from: unknown)
        XCTAssertNil(decoded.travel, "an unknown travel reads as not chosen")
        XCTAssertEqual(decoded.source, .beat)
        XCTAssertEqual(decoded.intensity, 0.5)
    }

    func testOnlyPunchesThatAddLightMove() {
        XCTAssertTrue(Composer2AudioModulation(source: .beat, travel: .roll).travels)
        XCTAssertTrue(Composer2AudioModulation(source: .onset, travel: .chase).travels)
        XCTAssertFalse(Composer2AudioModulation(source: .beat, travel: .together).travels)
        XCTAssertFalse(Composer2AudioModulation(source: .beat).travels)
        XCTAssertFalse(Composer2AudioModulation(source: .amplitude, travel: .roll).travels, "a swell has nowhere to go")
        XCTAssertFalse(Composer2AudioModulation(source: .beat, brightnessMode: .dimWhenQuiet, travel: .roll).travels)
        XCTAssertFalse(Composer2AudioModulation(source: .beat, targets: [.palettePosition], travel: .roll).travels)
    }

    func testChaseStepsCoverTheRoomInOrder() {
        for n in 2...12 {
            let plan = Composer2Hits.Plan(geometry: .linear(count: n))
            XCTAssertEqual(plan.groups, min(n, Composer2Hits.maxChaseSteps))
            XCTAssertEqual(Set(plan.group), Set(0..<plan.groups), "every step lights something (n=\(n))")
            XCTAssertEqual(plan.group, plan.group.sorted(), "steps follow the lights' order (n=\(n))")
            XCTAssertLessThanOrEqual(Dictionary(grouping: plan.group, by: { $0 }).values.map(\.count).max()!, 2,
                                     "a step is one light or a pair (n=\(n))")
        }
        XCTAssertEqual((0..<10).map { Composer2Hits.pingPong($0, count: 4) }, [0, 1, 2, 3, 2, 1, 0, 1, 2, 3])
        XCTAssertEqual((-3..<1).map { Composer2Hits.pingPong($0, count: 4) }, [3, 2, 1, 0])
        XCTAssertEqual((0..<4).map { Composer2Hits.pingPong($0, count: 2) }, [0, 1, 0, 1])
        XCTAssertEqual(Composer2Hits.pingPong(7, count: 1), 0)
    }

    // MARK: - Where and when each light is hit

    func testARollLandsOnTheBeatGoesOneWayForABarAndComesBack() {
        let n = 5
        let full = Composer2Hits.rollSeconds(beatInterval: 0.5)
        XCTAssertEqual(full, 0.25, accuracy: 1e-12, "half a beat at 120 BPM")
        // The beat before a turn leaves every light a flash budget before the
        // next beat reaches it: 0.5 − 0.34 s.
        let turn = 0.5 - BeatMath.FlashSafety.minOnsetLedgerPeriod
        XCTAssertEqual(Composer2Hits.sweep(.forward, next: .backward, gap: 0.5, beatInterval: 0.5), turn, accuracy: 1e-12)
        let samples = render(punchLook(.roll), geometry: .linear(count: n), beat: beat(120),
                             from: epoch + 0.4, to: epoch + 2.6)
        // Bar 1 (beats 0–3) rolls out, bar 2 (beats 4–7) comes back.
        let second = arrivals(samples, from: epoch + 0.5, to: epoch + 1.0)
        let fourth = arrivals(samples, from: epoch + 1.5, to: epoch + 2.0)
        let fifth = arrivals(samples, from: epoch + 2.0, to: epoch + 2.5)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            XCTAssertEqual(second[i], epoch + 0.5 + full * x, accuracy: within, "light \(i) rolls out")
            XCTAssertEqual(fourth[i], epoch + 1.5 + turn * x, accuracy: within, "light \(i): the beat before the turn is quicker")
            XCTAssertEqual(fifth[i], epoch + 2.0 + full * (1 - x), accuracy: within, "light \(i) comes back")
        }
        for (a, onBeat) in [(second, epoch + 0.5), (fourth, epoch + 1.5), (fifth, epoch + 2.0)] {
            XCTAssertEqual(a.min()!, onBeat, accuracy: within, "the first light lands on the beat")
        }
    }

    func testTheOneBurstsOutFromTheMiddle() {
        let g = Composer2SlotGeometry.linear(count: 5)
        // A burst always turns into a roll, so it leaves every light free in time.
        let burst = Composer2Hits.sweep(.burst, next: .backward, gap: 0.5, beatInterval: 0.5)
        XCTAssertEqual(burst, 0.5 - BeatMath.FlashSafety.minOnsetLedgerPeriod, accuracy: 1e-12)
        let samples = render(punchLook(.roll), geometry: g, beat: beat(120, knowsTheOne: true),
                             from: epoch + 1.9, to: epoch + 2.5)
        // Beat 4 is the one of the second bar.
        let a = arrivals(samples, from: epoch + 2.0, to: epoch + 2.5)
        XCTAssertEqual(a[2], epoch + 2.0, accuracy: within, "the middle light lands on the one")
        XCTAssertEqual(a[1], epoch + 2.0 + burst / 2, accuracy: within)
        XCTAssertEqual(a[3], a[1], accuracy: within, "both sides at once")
        XCTAssertEqual(a[0], epoch + 2.0 + burst, accuracy: within)
        XCTAssertEqual(a[4], a[0], accuracy: within)
        // Not sure where bars start: the same beat rolls instead.
        let unsure = render(punchLook(.roll), geometry: g, beat: beat(120), from: epoch + 1.9, to: epoch + 2.5)
        let rolled = arrivals(unsure, from: epoch + 2.0, to: epoch + 2.5)
        XCTAssertEqual(rolled[4], epoch + 2.0, accuracy: within, "bar 2 rolls back from the far end")
        XCTAssertGreaterThan(rolled[2], rolled[4])
    }

    func testARollFollowsWhereTheLightsSitNotTheirListOrder() {
        // Five lights along a long wall, listed out of order.
        let xs = [0.0, 3.0, 1.0, 2.0, 0.5]
        let g = Composer2SlotGeometry(points: xs.enumerated().map { (x: $0.element, z: Double($0.offset % 2) * 0.1) })
        // 60 BPM: a slow roll (0.4 s); beat 2 rolls out, beat 4 (bar 2) back.
        let samples = render(punchLook(.roll), geometry: g, beat: beat(60), from: epoch + 1.9, to: epoch + 5.0)
        let out = arrivals(samples, from: epoch + 2.0, to: epoch + 3.0)
        let back = arrivals(samples, from: epoch + 4.0, to: epoch + 5.0)
        let byX = xs.indices.sorted { xs[$0] < xs[$1] }
        let outOrder = out.indices.sorted { out[$0] < out[$1] }
        XCTAssertTrue(outOrder == byX || outOrder == Array(byX.reversed()), "\(outOrder) follows the wall")
        XCTAssertEqual(back.indices.sorted { back[$0] < back[$1] }, Array(outOrder.reversed()),
                       "and comes back the other way")
        // Spacing follows distance, not rank: 1 → 2 m takes twice 0 → 0.5 m.
        let gapNear = abs(out[4] - out[0]), gapFar = abs(out[3] - out[2])
        XCTAssertEqual(gapFar / gapNear, 2, accuracy: 0.25)
    }

    func testAChaseLandsEachBeatOnTheNextLightAndBounces() {
        let n = 4
        let samples = render(punchLook(.chase), geometry: .linear(count: n), beat: beat(120),
                             from: epoch, to: epoch + 6.2)
        for k in 1..<12 {
            let s = samples.min { abs($0.t - (epoch + Double(k) * 0.5 + 0.004)) < abs($1.t - (epoch + Double(k) * 0.5 + 0.004)) }!
            let lit = s.bri.indices.max { s.bri[$0] < s.bri[$1] }!
            XCTAssertEqual(lit, Composer2Hits.pingPong(k, count: n), "beat \(k)")
            let others = s.bri.enumerated().filter { $0.offset != lit }.map(\.element)
            XCTAssertGreaterThan(s.bri[lit] - others.max()!, 0.3, "one light at a time (beat \(k))")
        }
    }

    func testHeardHitsRollBackAndForthAndChaseStepsPerHit() {
        let g = Composer2SlotGeometry.linear(count: 5)
        // The third hit comes too soon after the second to start a wave.
        let onsets = [epoch + 0.5, epoch + 1.1, epoch + 1.2, epoch + 1.9]
        let heard: (Double) -> AudioFeatures = { t in
            var f = AudioFeatures()
            f.lastOnsetAt = onsets.last { $0 <= t } ?? 0
            return f
        }
        let roll = render(punchLook(.roll, source: .onset), geometry: g, beat: .none,
                          from: epoch + 0.4, to: epoch + 2.4, heard: heard)
        let first = arrivals(roll, from: onsets[0], to: onsets[1])
        let second = arrivals(roll, from: onsets[1], to: onsets[3])
        let third = arrivals(roll, from: onsets[3], to: epoch + 2.4)
        let w = Composer2Hits.rollSeconds(beatInterval: 0)
        XCTAssertEqual(first.min()!, onsets[0], accuracy: within, "a heard hit lands when it was heard")
        XCTAssertEqual(second.min()!, onsets[1], accuracy: within)
        XCTAssertEqual(third.min()!, onsets[3], accuracy: within, "the too-soon hit started no wave")
        XCTAssertEqual(first[4] - first[0], -(second[4] - second[0]), accuracy: within, "back and forth")
        XCTAssertEqual(abs(first[4] - first[0]), w, accuracy: within)

        let chase = render(punchLook(.chase, source: .onset), geometry: g, beat: .none,
                           from: epoch + 0.4, to: epoch + 2.4, heard: heard)
        var lit: [Int] = []
        for onset in [onsets[0], onsets[1], onsets[3]] {
            let s = chase.first { $0.t >= onset + 0.004 }!
            lit.append(s.bri.indices.max { s.bri[$0] < s.bri[$1] }!)
        }
        XCTAssertEqual(lit.count, Set(lit).count, "each heard hit lands on the next light: \(lit)")
        XCTAssertEqual(abs(lit[1] - lit[0]), 1)
        XCTAssertEqual(abs(lit[2] - lit[1]), 1)
    }

    // MARK: - Safety

    /// Every light, every tempo from slow to faster than the whole-room
    /// budget allows, every room size: two hits on one light are never
    /// closer than the flash budget — and every light is still hit.
    func testNoLightIsEverHitTwiceWithinTheFlashBudget() {
        let budget = BeatMath.FlashSafety.minOnsetLedgerPeriod
        for travel in [Composer2AudioModulation.Travel.roll, .chase] {
            for bpm in [60.0, 96, 120, 128, 150, 174, 186, 240] {
                for n in [2, 3, 5, 8, 10] {
                    for knowsTheOne in [false, true] {
                        let plan = Composer2Hits.Plan(geometry: ring(n))
                        let b = beat(bpm, knowsTheOne: knowsTheOne)
                        // A hit on a light is a peak in its level: a rise, then a fall.
                        var last = Array(repeating: -Double.infinity, count: n)
                        var hits = Array(repeating: 0, count: n)
                        var rising = Array(repeating: false, count: n)
                        var previous: [Double] = []
                        var levels: [Double] = []
                        var t = epoch
                        while t < epoch + 12 {
                            let grid = Composer2Hits.beatHits(travel, beat: b, at: t, groups: plan.groups, fade: 0.2)
                            Composer2Hits.levels(plan: plan, hits: grid, firstIsReference: true, at: t,
                                                 decay: 0.2, into: &levels)
                            if !previous.isEmpty {
                                for i in 0..<n {
                                    if levels[i] > previous[i] + 1e-9 {
                                        rising[i] = true
                                    } else if levels[i] < previous[i] - 1e-9, rising[i] {
                                        rising[i] = false
                                        let peak = t - step
                                        XCTAssertGreaterThanOrEqual(peak - last[i], budget - 2 * step - 1e-9,
                                            "\(travel) \(bpm) BPM n=\(n) one=\(knowsTheOne): light \(i) hit twice in \(peak - last[i]) s")
                                        hits[i] += 1
                                        last[i] = peak
                                    }
                                }
                            }
                            previous = levels
                            t += step
                        }
                        let every = Double(Composer2Hits.beatsPerHit(travel, beatInterval: b.beatInterval))
                        let gridHits = Int(12 / (every * b.beatInterval))
                        if travel == .roll {
                            // Nothing skipped: every light takes every roll.
                            XCTAssertGreaterThanOrEqual(hits.min()!, gridHits - 1, "\(bpm) BPM n=\(n): every light, every roll")
                        } else {
                            XCTAssertGreaterThan(hits.min()!, 0, "\(bpm) BPM n=\(n): the chase reaches every light")
                            XCTAssertEqual(Double(hits.reduce(0, +)), Double(gridHits * n) / Double(plan.groups),
                                           accuracy: Double(n + 2), "\(bpm) BPM n=\(n): one step per beat")
                        }
                    }
                }
            }
        }
    }

    func testAChaseKeepsEveryBeatWhereARollHalves() {
        // 186 BPM: beats 0.32 s apart, under the whole-room budget.
        XCTAssertEqual(Composer2Hits.beatsPerHit(.chase, beatInterval: 60 / 186.0), 1, "a chase lands every beat")
        XCTAssertEqual(Composer2Hits.beatsPerHit(.roll, beatInterval: 60 / 186.0), 2, "a roll every other beat")
        XCTAssertEqual(Composer2Hits.beatsPerHit(.roll, beatInterval: 60 / 128.0), 1)
        XCTAssertEqual(Composer2Hits.beatsPerHit(.roll, beatInterval: 60 / 150.0), 1)
        XCTAssertEqual(Composer2Hits.beatsPerHit(.roll, beatInterval: 60 / 152.0), 2)
        XCTAssertEqual(Composer2Hits.beatsPerHit(.chase, beatInterval: 60 / 128.0), 1)
        XCTAssertEqual(Composer2Hits.beatsPerHit(.chase, beatInterval: 60 / 340.0), 1)
    }

    func testDimFlashingLightsScalesTheHitAndTheDip() {
        let g = Composer2SlotGeometry.linear(count: 5)
        let full = render(punchLook(.roll), geometry: g, beat: beat(120), from: epoch + 1, to: epoch + 3)
        let dim = render(punchLook(.roll), geometry: g, beat: beat(120), from: epoch + 1, to: epoch + 3, eventCap: 0.3)
        let still = render(punchLook(nil), geometry: g, beat: .none, from: epoch + 1, to: epoch + 1.01)[0].bri[0]
        func swing(_ s: [Sample]) -> (dip: Double, rise: Double) {
            let all = s.flatMap(\.bri)
            return (still - all.min()!, all.max()! - all.min()!)
        }
        let a = swing(full), b = swing(dim)
        XCTAssertEqual(a.dip, still * Composer2Hits.duckShare * 0.8, accuracy: 0.01, "lights sit lower between hits")
        XCTAssertEqual(b.dip, a.dip * 0.3, accuracy: 0.01, "the dip scales with the cap")
        XCTAssertLessThan(b.rise, a.rise * 0.4, "and so does the hit")
    }

    /// Every built-in look, with Play Along engaged, rolling, chasing and
    /// hitting the whole room, through the real output path (engine + flash
    /// shaper) on the 20 ms grid and then an independent copy of the wire's
    /// gate. What must hold:
    ///  • the wire never holds a frame (a stutter) more than whole-room
    ///    hits make it;
    ///  • across the looks, moving hits need the shaper no more than whole-
    ///    room hits do — and on a fast song in a room of 8, every look needs
    ///    it less;
    ///  • no look leans on the shaper for more than a fifth of its frames.
    /// Measured, not hidden: in a room of 3 or 4, a look with its own
    /// one-light sparkles (Christmas Chase, Golden Ornaments, Campfire…)
    /// needs the shaper more with moving hits — a whole-room punch fading
    /// masks a sparkle's rise; a moving one doesn't — so the shaper softens
    /// those sparkles a little. The report prints every case.
    func testMovingHitsNeverLeanOnTheFlashGateMoreThanWholeRoomHits() {
        var report: [String] = []
        let cases: [(feel: Composer2PlayAlong.Feel, bpm: Double, n: Int)] = [
            (.hit, 96, 3), (.hit, 120, 4), (.hit, 128, 6), (.hit, 186, 8), (.groove, 120, 4), (.groove, 128, 6),
        ]
        for c in cases {
            var sums: [Composer2AudioModulation.Travel: Double] = [:]
            for look in Composer2PresetLibrary.all {
                var measured: [Composer2AudioModulation.Travel: (shaped: Double, holds: Int)] = [:]
                for travel in Composer2AudioModulation.Travel.allCases {
                    let m = play(look, feel: c.feel, travel: travel, bpm: c.bpm, n: c.n, seconds: 8)
                    measured[travel] = m
                    sums[travel, default: 0] += m.shaped
                }
                let together = measured[.together]!
                for travel in [Composer2AudioModulation.Travel.roll, .chase] {
                    let m = measured[travel]!
                    let label = "\(look.name) \(c.feel.title) \(Int(c.bpm)) BPM n=\(c.n) \(travel.rawValue)"
                    report.append(String(format: "%@ shaped=%.3f (together %.3f) holds=%d (together %d)",
                                         label, m.shaped, together.shaped, m.holds, together.holds))
                    XCTAssertLessThanOrEqual(m.holds, max(3, together.holds), "\(label): the wire gate held \(m.holds)")
                    XCTAssertLessThanOrEqual(m.shaped, max(0.2, together.shaped), "\(label) leans on the shaper (\(m.shaped))")
                    if c.n >= 8 {
                        XCTAssertLessThanOrEqual(m.shaped, together.shaped + 0.005, "\(label): a big room on a fast song")
                    }
                }
            }
            let looks = Double(Composer2PresetLibrary.all.count)
            let together = sums[.together]! / looks
            for travel in [Composer2AudioModulation.Travel.roll, .chase] {
                let mean = sums[travel]! / looks
                report.append(String(format: "MEAN %@ %.0f BPM n=%d %@ shaped=%.4f (together %.4f)",
                                     c.feel.title, c.bpm, c.n, travel.rawValue, mean, together))
                XCTAssertLessThanOrEqual(mean, together + 0.01,
                                         "\(c.feel.title) \(c.bpm) BPM n=\(c.n) \(travel): across the looks")
            }
        }
        print("Composer2LabHitsTests gate report:\n" + report.joined(separator: "\n"))
    }

    private func play(_ look: Composer2Composition, feel: Composer2PlayAlong.Feel = .hit,
                      travel: Composer2AudioModulation.Travel, bpm: Double, n: Int,
                      seconds: Double) -> (shaped: Double, holds: Int) {
        let output = Composer2LiveOutput(composition: look)
        output.eventCap = 1
        output.setPreviewGeometry(ring(n))
        output.playAlongRequested = true
        output.playAlongFeel = feel
        output.playAlongHits = travel
        let b = beat(bpm, knowsTheOne: true)
        var gate = BeatMath.FlashSafety.OnsetGate()
        var holds = 0
        let fps = 50.0
        // Engage first (the look lands on the next bar), then measure — the
        // gate and the shaper both run from the first frame, as on the wire.
        let start = epoch + 4
        var shapedBefore = 0, totalBefore = 0
        for step in 0..<Int((4 + seconds) * fps) {
            let t = epoch + Double(step) / fps
            if step == Int(4 * fps) {
                shapedBefore = output.shaper.shapedFrames
                totalBefore = output.shaper.totalFrames
            }
            let frames = output.evaluate(time: t - epoch, features: .silent, beat: b, hostNow: t)
            let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
            let reservation = gate.admit(frame: field, source: "wire", at: t,
                                         minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
            if !reservation.wasAdmitted, t >= start { holds += 1 }
            gate.commit(reservation, delivered: true, at: t)
        }
        XCTAssertEqual(output.playAlongWeight, 1, "\(look.name): Play Along engaged")
        let shaped = output.shaper.shapedFrames - shapedBefore
        return (Double(shaped) / Double(max(1, output.shaper.totalFrames - totalBefore)), holds)
    }

    // MARK: - Play Along carries it

    func testPlayAlongPutsEveryPunchOnTheChosenPath() {
        let neon = Composer2PlayAlong.apply(Composer2PresetLibrary.neonNights, feel: .groove, bpm: 120,
                                            category: .party, hits: .roll)
        let plain = Composer2PlayAlong.apply(Composer2PresetLibrary.neonNights, feel: .groove, bpm: 120, category: .party)
        XCTAssertEqual(neon.layers[0].audio.travel, .roll)
        var unmoved = neon.layers[0].audio
        unmoved.travel = nil
        XCTAssertEqual(unmoved, plain.layers[0].audio, "only where the punch lands changes")
        XCTAssertNil(plain.layers[0].audio.travel, "Together (the old behaviour) sets nothing")

        // Looks that already listen keep every sound setting; their punches move.
        for look in [Composer2PresetLibrary.beatDrop, Composer2PresetLibrary.clubPulse] {
            let out = Composer2PlayAlong.apply(look, feel: .hit, bpm: 128, category: .party, hits: .chase)
            for (a, b) in zip(look.layers, out.layers) {
                var authored = b.audio
                authored.travel = a.audio.travel
                XCTAssertEqual(authored, a.audio, "\(look.name): sound kept")
                var canMove = a.audio
                canMove.travel = .chase
                XCTAssertEqual(b.audio.travel, canMove.travels ? .chase : nil, "\(look.name) \(b.name)")
            }
        }
        // Beat Drop's bass swell has nowhere to go.
        let drop = Composer2PlayAlong.apply(Composer2PresetLibrary.beatDrop, feel: .hit, bpm: 128, category: .party, hits: .roll)
        XCTAssertNil(drop.layers[1].audio.travel)

        // A look that chose its own path keeps it.
        var own = Composer2PresetLibrary.clubPulse
        own.layers[0].audio.travel = .together
        XCTAssertEqual(Composer2PlayAlong.apply(own, feel: .hit, bpm: 128, category: .party, hits: .roll)
                        .layers[0].audio.travel, .together)

        // Glide adds no punches, Calm looks only breathe: nothing to move.
        let glide = Composer2PlayAlong.apply(Composer2PresetLibrary.neonNights, feel: .glide, bpm: 120,
                                             category: .party, hits: .roll)
        XCTAssertTrue(glide.layers.allSatisfy { $0.audio.travel == nil })
        for entry in Composer2ThemeCatalog.entries(in: .calm) {
            let calm = Composer2PlayAlong.apply(entry.composition, feel: .hit, bpm: 120, category: .calm, hits: .roll)
            XCTAssertTrue(calm.layers.allSatisfy { $0.audio.travel == nil }, entry.composition.name)
        }
        // Idempotent, like the rest of the transform.
        XCTAssertEqual(Composer2PlayAlong.apply(neon, feel: .groove, bpm: 120, category: .party, hits: .roll), neon)
    }

    func testTheSettingReachesTheLiveLook() {
        let output = Composer2LiveOutput(composition: Composer2PresetLibrary.neonNights)
        output.setPreviewGeometry(ring(6))
        output.playAlongRequested = true
        output.playAlongFeel = .groove
        output.playAlongHits = .roll
        let b = beat(120, knowsTheOne: true)
        var t = epoch
        while t < epoch + 3 {
            output.evaluate(time: t - epoch, beat: b, hostNow: t)
            t += 0.02
        }
        XCTAssertEqual(output.derived?.layers[0].audio.travel, .roll)
        output.playAlongHits = .chase
        output.evaluate(time: t - epoch, beat: b, hostNow: t)
        XCTAssertEqual(output.derived?.layers[0].audio.travel, .chase, "a change re-derives on the next frame")
        output.playAlongHits = .together
        output.evaluate(time: t + 0.02 - epoch, beat: b, hostNow: t + 0.02)
        XCTAssertNil(output.derived?.layers[0].audio.travel)
    }

    @MainActor
    func testSettingsRememberHitsAndDefaultToRoll() throws {
        let suite = "Composer2LabHitsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Composer2PlayAlongSettings(defaults: defaults)
        XCTAssertEqual(settings.hits, .roll, "moving hits are the default")
        settings.hits = .chase
        XCTAssertEqual(Composer2PlayAlongSettings(defaults: defaults).hits, .chase)
    }

    func testOneLightStillPunchesAsBefore() {
        let g = Composer2SlotGeometry.linear(count: 1)
        let moving = render(punchLook(.roll), geometry: g, beat: beat(120), from: epoch + 1, to: epoch + 2)
        let together = render(punchLook(nil), geometry: g, beat: beat(120), from: epoch + 1, to: epoch + 2)
        XCTAssertEqual(moving.map(\.bri), together.map(\.bri), "one light has nowhere to travel")
    }
}
