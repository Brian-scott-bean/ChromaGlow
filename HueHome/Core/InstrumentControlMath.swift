//
//  InstrumentControlMath.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (shared touch instrument).
//
//  The pure math behind the knob/fader gesture contract (spec §5), kept free
//  of SwiftUI so every mapping is unit-testable:
//
//  * DIRECT MANIPULATION — the same gesture that touches a control adjusts
//    it; value change is integrated per drag sample along the control's
//    primary axis.
//  * ADAPTIVE FINE CONTROL — moving the finger LATERALLY away from the
//    control during the drag progressively increases precision (lower gain);
//    returning restores normal response. No mode switch, monotonic,
//    clamped, and predictable — the properties the tests pin.
//  * SEMANTIC HAPTICS — ticks fire at meaning (default snap, range limits,
//    discrete steps), never per pixel.
//
//  Everything clamps. Neither the adaptive gain nor exact entry can carry a
//  value outside its range (spec §24).
//

import Foundation
import CoreGraphics

enum InstrumentControlMath {

    /// Distance from the control's axis within which response is 1:1.
    static let coarseZone: CGFloat = 60
    /// How quickly precision increases beyond the coarse zone.
    static let fineRamp: CGFloat = 120
    /// The precision floor — never slower than this fraction of coarse.
    static let minGain: Double = 0.15

    /// Gain for the current finger position: 1.0 near the control, ramping
    /// down toward `minGain` as the finger moves laterally away. Pure in the
    /// CURRENT distance, so moving back restores coarse response by itself.
    static func adaptiveGain(lateralDistance: CGFloat) -> Double {
        let d = abs(lateralDistance)
        guard d > coarseZone else { return 1.0 }
        let gain = 1.0 / (1.0 + Double((d - coarseZone) / fineRamp))
        return max(minGain, gain)
    }

    /// The value change for one drag sample. `axisDelta` is points moved
    /// along the primary axis since the LAST sample, in "increase" direction
    /// (the view negates upward y for vertical controls). `travel` is the
    /// points of axis motion that would sweep the full range at gain 1.
    static func valueDelta(axisDelta: CGFloat, travel: CGFloat,
                           range: ClosedRange<Double>, gain: Double) -> Double {
        guard travel > 0 else { return 0 }
        let span = range.upperBound - range.lowerBound
        return Double(axisDelta / travel) * span * gain
    }

    /// Apply a delta, clamped. The clamp is here — in the math — so no
    /// gesture path can bypass it.
    static func applying(delta: Double, to value: Double,
                         range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value + delta))
    }

    // ── Semantic haptic ticks ───────────────────────────────────

    enum Tick: Equatable {
        /// Crossed (or landed on) the control's default value.
        case defaultSnap
        /// Hit the range minimum or maximum.
        case limit
        /// Crossed into a new discrete step (index of the new step).
        case step(Int)
    }

    /// The tick a value transition earns, if any. Priority: limits beat the
    /// default snap beat step crossings — one tick per transition, never a
    /// buzz. `stepCount` divides the range into that many equal steps for
    /// stepped encoders; nil for continuous controls.
    static func semanticTick(previous: Double, new: Double,
                             range: ClosedRange<Double>,
                             defaultValue: Double? = nil,
                             stepCount: Int? = nil) -> Tick? {
        guard previous != new else { return nil }
        if new == range.lowerBound || new == range.upperBound { return .limit }
        if let defaultValue,
           (previous < defaultValue && new >= defaultValue)
            || (previous > defaultValue && new <= defaultValue) {
            return .defaultSnap
        }
        if let stepCount, stepCount > 1 {
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return nil }
            let stepOf = { (v: Double) -> Int in
                let t = (v - range.lowerBound) / span
                return min(stepCount - 1, max(0, Int(t * Double(stepCount))))
            }
            let newStep = stepOf(new)
            if newStep != stepOf(previous) { return .step(newStep) }
        }
        return nil
    }
}

// ── Exact-entry parsing (shared by every readout) ───────────────

/// The typed-value parser, extracted from `StageSlider` so the knob and
/// fader share one behavior: leading number, unit suffix ignored, clamped
/// into range, nil for non-numbers. The clamp here is what makes exact
/// entry unable to bypass a control's range (spec §24).
enum StageDraftMath {
    static func parseDraft(_ text: String, range: ClosedRange<Double>) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var numeric = ""
        var seenDot = false
        for (i, ch) in trimmed.enumerated() {
            if ch.isNumber { numeric.append(ch) }
            else if (ch == "." || ch == ",") && !seenDot { numeric.append("."); seenDot = true }
            else if ch == "-" && i == 0 { numeric.append(ch) }
            else { break }
        }
        guard let parsed = Double(numeric) else { return nil }
        return min(range.upperBound, max(range.lowerBound, parsed))
    }
}
