// FeatureFlags.swift
// ChromaGlow — Core
//
// Local, compile-time feature flags. Deliberately dumb: no provider
// protocol, no remote config — AGENTS.md backend rules say start with
// local interfaces and grow only when a backend exists.

import Foundation

// Experiment guard: the Spotify Connect PCM receiver
// (CHROMAGLOW_EXPERIMENTAL_SPOTIFY) must never reach an App Store build. Two
// configurations set it: Debug-SpotifyExperimental (local runs) and
// Release-SpotifyExperimental — the optimized archive for INTERNAL TestFlight
// builds only, which also sets CHROMAGLOW_INTERNAL_TESTFLIGHT. (TestFlight 907
// was a Debug archive: -Onone, debug-only work on, no dSYMs.) The flag alone
// in any other optimized build fails here.
#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY && !DEBUG && !CHROMAGLOW_INTERNAL_TESTFLIGHT
#error("CHROMAGLOW_EXPERIMENTAL_SPOTIFY may only be enabled in Debug-SpotifyExperimental or the internal-TestFlight Release-SpotifyExperimental build")
#endif

enum FeatureFlags {
    /// Spotify music source (docs/ios/music-integration-design-2026-07.md §2.3).
    /// Dev-only until Spotify extended-quota access is realistic: a new app's
    /// Spotify integration works for at most 5 allowlisted accounts, so
    /// Release builds ship with it off.
    #if DEBUG || CHROMAGLOW_INTERNAL_TESTFLIGHT
    static let spotifySource = true
    #else
    static let spotifySource = false
    #endif
}
