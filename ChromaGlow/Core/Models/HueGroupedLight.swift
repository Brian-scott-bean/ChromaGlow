// HueGroupedLight.swift
// ChromaGlow — Story 1.2 / 1.3
//
// Typed model for the Hue V2 /clip/v2/resource/grouped_light resource.
// This is the control surface for toggling an entire room on/off.

import Foundation

struct HueGroupedLight: Decodable, Identifiable {
    let id: String
    let on: OnState
    let dimming: DimmingState?
    let type: String?
}
