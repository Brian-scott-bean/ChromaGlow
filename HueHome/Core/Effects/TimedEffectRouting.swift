// TimedEffectRouting.swift
// ChromaGlow — Round 3 Phase C (full Hue power)
//
// Pure router: bridge-side `timed_effects` (sunrise/sunset that keep
// ramping after the app is killed) vs the proven app-driven
// dynamics.duration ramp. Native wins ONLY when the firmware can reproduce
// the exact look — it takes nothing but a duration, so any customized
// start/end brightness or warmth, partial light support, or an unmappable
// effect (Wind Down) uses the app ramp.

import Foundation

enum TimedEffectRouting {

    enum Route: Equatable {
        case native(effect: String)
        case appRamp(reason: Reason)
    }

    enum Reason: Equatable {
        case notMappable      // no firmware equivalent (winddown)
        case customized       // user moved a slider the firmware can't honor
        case noLights
        case partialSupport   // a half-native sunrise looks broken
    }

    static func route(effectID: String,
                      paramsAreDefault: Bool,
                      lights: [HueLight]) -> Route {
        let nativeName: String?
        switch effectID {
        case "sunrise": nativeName = "sunrise"
        case "sunset":  nativeName = "sunset"
        default:        nativeName = nil
        }
        guard let nativeName else { return .appRamp(reason: .notMappable) }
        guard paramsAreDefault else { return .appRamp(reason: .customized) }
        guard !lights.isEmpty else { return .appRamp(reason: .noLights) }
        guard EffectCapabilityResolver.canRunNativeTimedEffect(nativeName, lights: lights) else {
            return .appRamp(reason: .partialSupport)
        }
        return .native(effect: nativeName)
    }

    /// True when the card's sliders/toggles sit at the exact defaults the
    /// firmware ramp reproduces (values mirror the EffectLibrary cards).
    static func paramsAreDefault(effectID: String, state: EffectParamState) -> Bool {
        switch effectID {
        case "sunrise":
            return state.sliderValue("startBrightness", default: 1) == 1
                && state.sliderValue("endBrightness", default: 90) == 90
                && state.sliderValue("startMirek", default: 490) == 490
                && state.sliderValue("endMirek", default: 230) == 230
        case "sunset":
            return state.sliderValue("endBrightness", default: 10) == 10
                && state.sliderValue("endMirek", default: 490) == 490
                && state.boolValue("turnOff", default: true) == true
        default:
            return false
        }
    }
}
