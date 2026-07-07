// ControlMappingEngine.swift
// ChromaGlow — Round 3 Phase G (Tap Dial as DJ controller)
//
// Pure mapping from physical-input events (button / relative_rotary SSE)
// to app actions. The "DJ Mode" template: rotate the dial to nudge BPM,
// button 1 for tap tempo (long-press = downbeat resync), buttons 2–4 as
// punch pads. No I/O here — the orchestrator executes the returned action.

import Foundation

// MARK: - ControlAction

enum ControlAction: Equatable {
    case tapTempo
    case resyncDownbeat
    case nudgeBPM(delta: Double)
    case punchBurst(slot: Int)      // 0…2 (buttons 2–4)
    case none
}

// MARK: - ControlMappingEngine

/// Value type; the orchestrator owns one instance per session. The rotary
/// accumulator coalesces the dial's step bursts into ≤1 nudge per 100 ms —
/// pending steps are never dropped, only deferred to the next emit.
struct ControlMappingEngine {

    static let windowSeconds = 0.100
    /// ~one full dial revolution (≈90 steps) ≈ ±18 BPM.
    static let bpmPerStep = 0.2

    private var pendingSteps = 0
    private var lastEmitTime = -1.0

    // ── Rotary ──

    mutating func handleRotary(clockwise: Bool, steps: Int, now: Double) -> ControlAction {
        pendingSteps += clockwise ? steps : -steps
        guard now - lastEmitTime >= Self.windowSeconds else { return .none }
        defer { pendingSteps = 0; lastEmitTime = now }
        let delta = Double(pendingSteps) * Self.bpmPerStep
        return delta == 0 ? .none : .nudgeBPM(delta: delta)
    }

    // ── Buttons (Tap Dial: control_id 1…4) ──

    /// initial_press everywhere latency matters (tap tempo, punches);
    /// long_press on button 1 re-anchors the downbeat.
    func handleButton(controlID: Int, event: String) -> ControlAction {
        switch (controlID, event) {
        case (1, "initial_press"): return .tapTempo
        case (1, "long_press"):    return .resyncDownbeat
        case (2...4, "initial_press"): return .punchBurst(slot: controlID - 2)
        default: return .none
        }
    }
}

// MARK: - Button resource (control_id resolution)

/// Minimal decode of GET /clip/v2/resource/button — maps each button
/// resource UUID to its physical position on the device (control_id 1…4).
struct HueButtonResource: Decodable {
    let id: String
    let metadata: Metadata?
    struct Metadata: Decodable { let control_id: Int? }
}
