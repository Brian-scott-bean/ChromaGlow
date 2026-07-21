// FeatureFlags.swift
// ChromaGlow — Core
//
// Local, compile-time feature flags. Deliberately dumb: no provider
// protocol, no remote config — AGENTS.md backend rules say start with
// local interfaces and grow only when a backend exists.

import Foundation

enum FeatureFlags {
    /// Spotify music source (docs/ios/music-integration-design-2026-07.md §2.3).
    /// Dev-only until Spotify extended-quota access is realistic: a new app's
    /// Spotify integration works for at most 5 allowlisted accounts, so
    /// Release builds ship with it off.
    #if DEBUG
    static let spotifySource = true
    #else
    static let spotifySource = false
    #endif
}
