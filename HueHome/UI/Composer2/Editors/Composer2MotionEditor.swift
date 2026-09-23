// Composer2MotionEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// How colour travels through the room: kind, speed, direction, spread,
// edges. Direction uses the room's real axis when the bridge gave positions.

import SwiftUI

struct Composer2MotionEditorContent: View {
    let document: Composer2Document

    private var motion: Composer2Motion { document.selectedLayer.motion }

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Pattern") {
                Composer2ChipRow(title: "Kind", options: [
                    ("Still", Composer2Motion.Kind.static, "pause.circle"),
                    ("Flow", .flow, "wind"),
                    ("Chase", .chase, "arrow.right.to.line"),
                    ("Wave", .wave, "water.waves"),
                    ("Bounce", .bounce, "arrow.left.arrow.right"),
                    ("Scatter", .scatter, "sparkles"),
                    ("Organic", .organic, "leaf"),
                    ("March", .march, "lightbulb.2")
                ], selection: document.layerBinding(\.motion.kind))
                Composer2SliderRow(title: "Speed", value: document.layerBinding(\.motion.speedNormalized), range: 0...1,
                                   format: { _ in
                                       motion.kind == .march
                                           ? composer2Seconds(motion.stepSeconds) + " per step"
                                           : composer2Seconds(motion.sanitizedPeriod) + " per cycle"
                                   })
                if motion.kind == .march {
                    Composer2StepperRow(title: "Pattern", value: document.layerBinding(\.motion.steps), range: 2...12,
                                        format: { "\($0) lights" })
                    Composer2SliderRow(title: "Lit", value: document.layerBinding(\.motion.travelWidth), range: 0.05...1,
                                       format: { width in
                                           let k = motion.patternLength
                                           let lit = width >= 0.999 ? k : max(1, Int((width * Double(k)).rounded()))
                                           return lit >= k ? "every light" : "\(lit) in \(k)"
                                       })
                }
                StageToggleRow(title: "Reverse direction", isOn: document.layerBinding(\.motion.reverse))
                StageToggleRow(title: "Mirror from both ends", isOn: document.layerBinding(\.motion.mirror))
            }
            Composer2EditorSection(title: "Direction",
                                   subtitle: document.roomContext.layout.positionsAreEstimated
                                       ? "Positions are estimated for this room, so direction follows the light order."
                                       : "Direction follows your Entertainment Area's real layout.") {
                Composer2ChipRow(title: "Axis", options: [
                    ("Along the room", Composer2Motion.AxisKind.principal, "arrow.left.and.right"),
                    ("Angle", .angle, "location.north.line"),
                    ("From the centre", .radial, "circle.circle"),
                    ("Around", .angular, "arrow.triangle.2.circlepath")
                ], selection: document.layerBinding(\.motion.axisKind))
                if motion.axisKind == .angle {
                    Composer2SliderRow(title: "Angle", value: document.layerBinding(\.motion.angleDegrees), range: 0...360,
                                       format: { "\(Int($0.rounded()))°" })
                }
            }
            Composer2EditorSection(title: "Shape") {
                Composer2SliderRow(title: "Spread", value: document.layerBinding(\.motion.spread), range: 0...1)
                Composer2SliderRow(title: "Phase offset", value: document.layerBinding(\.motion.phaseOffset), range: 0...1)
                Composer2SliderRow(title: "Smoothness", value: document.layerBinding(\.motion.smoothness), range: 0...1)
                Composer2SliderRow(title: "Travel width", value: document.layerBinding(\.motion.travelWidth), range: 0.05...1,
                                   format: { $0 >= 0.999 ? "whole room" : "\(Int(($0 * 100).rounded()))%" })
                if motion.kind == .chase {
                    Composer2StepperRow(title: "Spacing", value: document.layerBinding(\.motion.steps), range: 0...12,
                                        format: { $0 == 0 ? "continuous" : "\($0) steps" })
                }
                if motion.kind == .organic {
                    Composer2SliderRow(title: "Detail", value: document.layerBinding(\.motion.scale), range: 0.25...4,
                                       format: { String(format: "×%.1f", $0) })
                }
                Composer2ChipRow(title: "At the edges", options: [
                    ("Wrap", Composer2Motion.Edge.wrap, "repeat"),
                    ("Bounce", .bounce, "arrow.uturn.left"),
                    ("Stop", .clamp, "stop")
                ], selection: document.layerBinding(\.motion.edge))
            }
        }
    }
}
