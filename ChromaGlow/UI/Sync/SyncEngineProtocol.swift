// SyncEngineProtocol.swift
// ChromaGlow — Sync Mode Architecture
//
// Defines the protocol that all sync engines conform to, plus shared types.
// Each engine receives raw audio buffers and produces light control output.

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Engine Type

/// The available sync engine modes. Only engines that are implemented
/// should be included; new ones are added as they ship.
enum SyncEngineType: String, CaseIterable, Identifiable {
    case visualizer = "Visualizer"
    case gaming     = "Gaming"
    case ambient    = "Ambient"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .visualizer: return "waveform.path.ecg"
        case .gaming:     return "gamecontroller.fill"
        case .ambient:    return "moon.stars.fill"
        }
    }

    var description: String {
        switch self {
        case .visualizer: return "Frequency spectrum mapped to light color and brightness"
        case .gaming:     return "Instant flash on sound spikes — perfect for games and action"
        case .ambient:    return "Slow breathing pulse — presence-aware, calm background light"
        }
    }

    var accentColor: Color {
        switch self {
        case .visualizer: return Color(hue: 0.75, saturation: 0.7, brightness: 0.95)
        case .gaming:     return Color(hue: 0.08, saturation: 0.9, brightness: 0.95)
        case .ambient:    return Color(hue: 0.60, saturation: 0.6, brightness: 0.85)
        }
    }
}

// MARK: - Engine Output

/// The result of one processing frame — tells the light sender what to do.
struct SyncEngineOutput {
    /// Whether lights should be on (false if signal is below noise floor).
    let on: Bool
    /// Target brightness 0–100%.
    let brightness: Double
    /// Color temperature in mirek (153–500). Nil if using CIE xy instead.
    let mirek: Int?
    /// CIE xy color. Nil if using mirek instead.
    let xy: (x: Double, y: Double)?
    /// Transition duration in ms for the light command.
    let transitionMs: Int

    static let idle = SyncEngineOutput(on: false, brightness: 0, mirek: nil, xy: nil, transitionMs: 80)
}

// MARK: - Engine Protocol

/// All sync engines conform to this protocol.
/// Engines are value-processing pipelines: audio in → light output out.
/// They also expose UI-visible state (bar heights, levels, etc.) for visualization.
protocol SyncEngine: AnyObject {
    /// Process one audio buffer and return the light control output.
    /// Called on the audio thread — must be fast. Heavy UI updates
    /// should be dispatched to MainActor by the engine itself.
    func process(buffer: AVAudioPCMBuffer, sampleRate: Float) -> SyncEngineOutput

    /// Reset all internal state (smoothing buffers, levels, etc.).
    /// Called when the engine is deactivated or stopped.
    func reset()
}

// MARK: - Visualizer Color Mode

/// Sub-options within the Visualizer engine that change color mapping.
enum VisualizerColorMode: String, CaseIterable, Identifiable {
    case reactive = "Reactive"
    case pulse    = "Pulse"
    case warm     = "Warm"
    case cool     = "Cool"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .reactive: return "waveform.path.ecg"
        case .pulse:    return "circle.fill"
        case .warm:     return "flame.fill"
        case .cool:     return "snowflake"
        }
    }

    var color: Color {
        switch self {
        case .reactive: return .purple
        case .pulse:    return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:     return .orange
        case .cool:     return .cyan
        }
    }
}
