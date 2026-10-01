// FeatureFlags.swift
// ChromaGlow — Core
//
// Local, compile-time feature flags. Deliberately dumb: no provider
// protocol, no remote config — AGENTS.md backend rules say start with
// local interfaces and grow only when a backend exists.

import Foundation

// LOCAL-ONLY experiment guard: the Spotify Connect PCM receiver
// (CHROMAGLOW_EXPERIMENTAL_SPOTIFY, set only by the Debug-SpotifyExperimental
// configuration) must never reach a Release / App Store / TestFlight build.
#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY && !DEBUG
#error("CHROMAGLOW_EXPERIMENTAL_SPOTIFY is a local Debug-only experiment and must never be enabled in a Release build")
#endif

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
