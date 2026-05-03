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
enum EffectLoops {

    // ─────────────────────────────────────────────
    // MARK: Strobe
    // ─────────────────────────────────────────────

    /// Alternates all lights between `onColor` and `offBrightness` at `bpm` beats/min.
    static func strobe(
        lights:        [LightDisplayItem],
        api:           HueAPIClient,
        bpm:           Double,    // 30...480
        dutyCycle:     Double,    // 0.10...0.90
        onXY:          (Double, Double),
        offBrightness: Double
    ) -> @Sendable () async throws -> Void {
        return {
            let periodNs   = UInt64(60_000_000_000 / bpm)
            let onNs       = UInt64(Double(periodNs) * dutyCycle)
            let offNs      = periodNs - onNs

            while !Task.isCancelled {
                // ON phase
                await EffectLoops.setAll(lights: lights, api: api,
                                         on: true, brightness: 100,
                                         xy: onXY, duration: 0)
                try await Task.sleep(nanoseconds: onNs)
                guard !Task.isCancelled else { return }

                // OFF phase
                await EffectLoops.setAll(lights: lights, api: api,
                                         on: offBrightness <= 0,
                                         brightness: offBrightness,
                                         xy: onXY, duration: 0)
                try await Task.sleep(nanoseconds: offNs)
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Party
    // ─────────────────────────────────────────────

    static func party(
        lights:   [LightDisplayItem],
        api:      HueAPIClient,
        speed:    Double,           // 1...10
        palette:  [(Double, Double)],  // array of CIE xy pairs
        sync:     Bool,
        flash:    Bool
    ) -> @Sendable () async throws -> Void {
        return {
            let intervalNs = UInt64((1.1 - speed / 10.0) * 1_500_000_000)

            while !Task.isCancelled {
                if sync {
                    let xy = palette.randomElement() ?? (0.3, 0.3)
                    await EffectLoops.setAll(lights: lights, api: api,
                                             on: true, brightness: 90,
                                             xy: xy, duration: 200)
                } else {
                    for light in lights {
                        guard !Task.isCancelled else { return }
                        let xy = palette.randomElement() ?? (0.3, 0.3)
                        await EffectLoops.setOne(light: light, api: api,
                                                  on: true, brightness: 80,
                                                  xy: xy, duration: 300)
                    }
                }

                // Occasional white flash
                if flash && Int.random(in: 0..<8) == 0 {
                    await EffectLoops.setAll(lights: lights, api: api,
                                             on: true, brightness: 100,
                                             xy: (0.32, 0.33), duration: 0)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                }

                try await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Thunderstorm
    // ─────────────────────────────────────────────

    static func thunderstorm(
        lights:           [LightDisplayItem],
        api:              HueAPIClient,
        frequencyIndex:   Int,   // 0=Rare 1=Occasional 2=Frequent
        baseXY:           (Double, Double),
        flashXY:          (Double, Double),
        baseBrightness:   Double
    ) -> @Sendable () async throws -> Void {
        return {
            // Base calm state
            await EffectLoops.setAll(lights: lights, api: api,
                                     on: true, brightness: baseBrightness,
                                     xy: baseXY, duration: 2000)

            let avgWaitMs: UInt64 = [12_000, 6_000, 2_500][frequencyIndex]

            while !Task.isCancelled {
                // Random wait before next strike
                let waitNs = UInt64.random(in: avgWaitMs * 500_000 ..< avgWaitMs * 1_500_000)
                try await Task.sleep(nanoseconds: waitNs)
                guard !Task.isCancelled else { return }

                // Lightning burst: 1–3 quick flashes
                let flashes = Int.random(in: 1...3)
                for _ in 0..<flashes {
                    guard !Task.isCancelled else { return }
                    await EffectLoops.setAll(lights: lights, api: api,
                                             on: true, brightness: 100,
                                             xy: flashXY, duration: 0)
                    try await Task.sleep(nanoseconds: UInt64.random(in: 40_000_000...120_000_000))
                    guard !Task.isCancelled else { return }
                    await EffectLoops.setAll(lights: lights, api: api,
                                             on: true, brightness: baseBrightness,
                                             xy: baseXY, duration: 0)
                    try await Task.sleep(nanoseconds: UInt64.random(in: 60_000_000...200_000_000))
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────

    static func setAll(
        lights: [LightDisplayItem], api: HueAPIClient,
        on: Bool, brightness: Double, xy: (Double, Double), duration: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for light in lights {
                group.addTask {
                    await EffectLoops.setOne(light: light, api: api,
                                             on: on, brightness: brightness,
                                             xy: xy, duration: duration)
                }
            }
        }
    }

    static func setOne(
        light: LightDisplayItem, api: HueAPIClient,
        on: Bool, brightness: Double, xy: (Double, Double), duration: Int
    ) async {
        try? await api.setLightEffect(
            id:         light.id,    // LightDisplayItem.id == CLIP v2 light resource UUID
            on:         on,
            brightness: brightness,
            xy:         xy,
            mirek:      nil,
            duration:   duration
        )
    }
}
