// EffectEngine.swift
// CastChroma — Effects Engine
//
// Actor that manages exactly one running app-driven effect loop at a time.
// Cancels and replaces whenever a new effect starts.
// Bridge-native and one-shot effects don't use the engine at all.

import Foundation

// MARK: - EffectEngine

actor EffectEngine {

    private var currentTask: Task<Void, Never>?
    private(set) var isRunning: Bool = false
    private(set) var runningEffectID: String?

    // MARK: - Control

    /// Start a new looping effect, cancelling any currently running one.
    func start(effectID: String, loop: @escaping () async throws -> Void) {
        stop()          // cancel previous immediately
        isRunning     = true
        runningEffectID = effectID

        currentTask = Task {
            do {
                try await loop()
            } catch is CancellationError {
                // Normal cancellation — do nothing
            } catch {
                // Unexpected error — stop cleanly
            }
            isRunning       = false
            runningEffectID = nil
        }
    }

    /// Stop any running effect. Lights remain in their last state.
    func stop() {
        currentTask?.cancel()
        currentTask     = nil
        isRunning       = false
        runningEffectID = nil
    }
}

// MARK: - EffectLoops

/// Static helpers that build the async loop body for app-driven effects.
/// Each loop checks `Task.isCancelled` and returns when cancelled.
///
/// M-14: every frame goes through the per-bridge `BridgeCommandGate`
/// (~10 cmd/sec) and same-color frames collapse to ONE grouped_light PUT
/// when a `groupedLightID` is available — a 10-light strobe used to fire
/// ~40 unpaced per-light PUTs/sec with every 429 swallowed by `try?`.
/// A failed frame triggers an extra backoff sleep instead of hammering on.
enum EffectLoops {

    /// Extra sleep after a frame that failed even with the gate's retry.
    static let failureBackoffNs: UInt64 = 500_000_000

    // ─────────────────────────────────────────────
    // MARK: Strobe
    // ─────────────────────────────────────────────

    /// Alternates all lights between `onColor` and `offBrightness` at `bpm` beats/min.
    static func strobe(
        lights:         [LightDisplayItem],
        api:            HueAPIClient,
        groupedLightID: String?,
        gate:           BridgeCommandGate,
        bpm:            Double,    // 30...480
        dutyCycle:      Double,    // 0.10...0.90
        onXY:           (Double, Double),
        offBrightness:  Double
    ) -> @Sendable () async throws -> Void {
        return {
            // Defense-in-depth (L-41 class): bpm ≤ 0 divides to ∞ (UInt64 trap)
            // and dutyCycle > 1 underflows offNs. Clamp to the schema ranges.
            let bpm        = min(max(bpm, 30), 480)
            let dutyCycle  = min(max(dutyCycle, 0.10), 0.90)
            let periodNs   = UInt64(60_000_000_000 / bpm)
            let onNs       = UInt64(Double(periodNs) * dutyCycle)
            let offNs      = periodNs - onNs

            while !Task.isCancelled {
                // ON phase
                var ok = await EffectLoops.setAll(lights: lights, api: api,
                                                  groupedLightID: groupedLightID, gate: gate,
                                                  on: true, brightness: 100,
                                                  xy: onXY, duration: 0)
                try await Task.sleep(nanoseconds: ok ? onNs : onNs + EffectLoops.failureBackoffNs)
                guard !Task.isCancelled else { return }

                // OFF phase
                ok = await EffectLoops.setAll(lights: lights, api: api,
                                              groupedLightID: groupedLightID, gate: gate,
                                              on: offBrightness <= 0,
                                              brightness: offBrightness,
                                              xy: onXY, duration: 0)
                try await Task.sleep(nanoseconds: ok ? offNs : offNs + EffectLoops.failureBackoffNs)
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Party
    // ─────────────────────────────────────────────

    static func party(
        lights:         [LightDisplayItem],
        api:            HueAPIClient,
        groupedLightID: String?,
        gate:           BridgeCommandGate,
        speed:          Double,           // 1...10
        palette:        [(Double, Double)],  // array of CIE xy pairs
        sync:           Bool,
        flash:          Bool
    ) -> @Sendable () async throws -> Void {
        return {
            // Defense-in-depth (L-41): speed > 11 makes the interval negative —
            // UInt64.init traps. Clamp to the schema range.
            let speed      = min(max(speed, 1), 10)
            let intervalNs = UInt64((1.1 - speed / 10.0) * 1_500_000_000)

            while !Task.isCancelled {
                var frameOK = true
                if sync {
                    let xy = palette.randomElement() ?? (0.3, 0.3)
                    frameOK = await EffectLoops.setAll(lights: lights, api: api,
                                                       groupedLightID: groupedLightID, gate: gate,
                                                       on: true, brightness: 90,
                                                       xy: xy, duration: 200)
                } else {
                    // Per-light colors differ — cannot collapse; the gate
                    // paces each PUT so this no longer bursts unthrottled.
                    for light in lights {
                        guard !Task.isCancelled else { return }
                        let xy = palette.randomElement() ?? (0.3, 0.3)
                        let ok = await EffectLoops.setOne(light: light, api: api, gate: gate,
                                                          on: true, brightness: 80,
                                                          xy: xy, duration: 300)
                        frameOK = frameOK && ok
                    }
                }

                // Occasional white flash
                if flash && Int.random(in: 0..<8) == 0 {
                    _ = await EffectLoops.setAll(lights: lights, api: api,
                                                 groupedLightID: groupedLightID, gate: gate,
                                                 on: true, brightness: 100,
                                                 xy: (0.32, 0.33), duration: 0)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                }

                try await Task.sleep(nanoseconds: frameOK ? intervalNs : intervalNs + EffectLoops.failureBackoffNs)
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Thunderstorm
    // ─────────────────────────────────────────────

    static func thunderstorm(
        lights:           [LightDisplayItem],
        api:              HueAPIClient,
        groupedLightID:   String?,
        gate:             BridgeCommandGate,
        frequencyIndex:   Int,   // 0=Rare 1=Occasional 2=Frequent
        baseXY:           (Double, Double),
        flashXY:          (Double, Double),
        baseBrightness:   Double
    ) -> @Sendable () async throws -> Void {
        return {
            // Base calm state
            _ = await EffectLoops.setAll(lights: lights, api: api,
                                         groupedLightID: groupedLightID, gate: gate,
                                         on: true, brightness: baseBrightness,
                                         xy: baseXY, duration: 2000)

            // Defense-in-depth (L-41): a drifted preset index would trap here.
            let avgWaitMs: UInt64 = [12_000, 6_000, 2_500][max(0, min(2, frequencyIndex))]

            while !Task.isCancelled {
                // Random wait before next strike
                let waitNs = UInt64.random(in: avgWaitMs * 500_000 ..< avgWaitMs * 1_500_000)
                try await Task.sleep(nanoseconds: waitNs)
                guard !Task.isCancelled else { return }

                // Lightning burst: 1–3 quick flashes
                let flashes = Int.random(in: 1...3)
                for _ in 0..<flashes {
                    guard !Task.isCancelled else { return }
                    let flashOK = await EffectLoops.setAll(lights: lights, api: api,
                                                           groupedLightID: groupedLightID, gate: gate,
                                                           on: true, brightness: 100,
                                                           xy: flashXY, duration: 0)
                    try await Task.sleep(nanoseconds: UInt64.random(in: 40_000_000...120_000_000))
                    guard !Task.isCancelled else { return }
                    let calmOK = await EffectLoops.setAll(lights: lights, api: api,
                                                          groupedLightID: groupedLightID, gate: gate,
                                                          on: true, brightness: baseBrightness,
                                                          xy: baseXY, duration: 0)
                    let restNs = UInt64.random(in: 60_000_000...200_000_000)
                    try await Task.sleep(nanoseconds: (flashOK && calmOK) ? restNs : restNs + EffectLoops.failureBackoffNs)
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────

    /// Applies ONE state to every light. Because the state is identical for
    /// all lights, this collapses to a single grouped_light PUT when the
    /// room's groupedLightID is available (M-14) — one paced command instead
    /// of N. Falls back to gate-paced per-light PUTs otherwise.
    /// Returns false when any command still failed after the gate's retry.
    static func setAll(
        lights: [LightDisplayItem], api: HueAPIClient,
        groupedLightID: String?, gate: BridgeCommandGate,
        on: Bool, brightness: Double, xy: (Double, Double), duration: Int
    ) async -> Bool {
        if let groupedLightID {
            // retry: false — the next frame supersedes a failed one.
            let error = await gate.send(retry: false) {
                try await api.setGroupedLightEffect(
                    id:         groupedLightID,
                    on:         on,
                    brightness: brightness,
                    xy:         xy,
                    mirek:      nil,
                    duration:   duration
                )
            }
            return error == nil
        }
        var allOK = true
        for light in lights {
            let ok = await setOne(light: light, api: api, gate: gate,
                                  on: on, brightness: brightness,
                                  xy: xy, duration: duration)
            allOK = allOK && ok
        }
        return allOK
    }

    /// One gate-paced per-light PUT. Returns false on persistent failure —
    /// callers back off instead of `try?`-hiding rate-limit errors.
    static func setOne(
        light: LightDisplayItem, api: HueAPIClient, gate: BridgeCommandGate,
        on: Bool, brightness: Double, xy: (Double, Double), duration: Int
    ) async -> Bool {
        // retry: false — the next frame supersedes a failed one.
        let error = await gate.send(retry: false) {
            try await api.setLightEffect(
                id:         light.id,    // LightDisplayItem.id == CLIP v2 light resource UUID
                on:         on,
                brightness: brightness,
                xy:         xy,
                mirek:      nil,
                duration:   duration
            )
        }
        return error == nil
    }
}
