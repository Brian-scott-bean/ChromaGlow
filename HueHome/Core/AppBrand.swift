// AppBrand.swift
// ChromaGlow — Centralized brand constants
//
// All user-visible brand strings live here. To rebrand the app,
// update these values and the CFBundleDisplayName in Info.plist.
// Internal module names (HueHome, com.lightshade.app) are left
// as-is — they're never user-visible and changing them risks
// breaking code signing, Keychain, and derived data.

import Foundation

enum AppBrand {

    // ── User-visible ─────────────────────────────
    /// The display name shown in UI text, alerts, and onboarding.
    static let displayName = "ChromaGlow"

    /// Short tagline for splash / about screens.
    static let tagline     = "Smart lighting, reimagined."

    /// The devicetype string sent to the Hue Bridge during pairing.
    /// Format: "<appname>#<platform>" — Bridge stores this as the app identity.
    static let hueDeviceType = "chromaglow#ios"

    // ── Internal (never change unless absolutely necessary) ──
    /// Bundle ID — changing this requires new provisioning profiles + App Store Connect entry.
    /// static let bundleID = "com.lightshade.app"  // reference only — set in Xcode target, not here
}
