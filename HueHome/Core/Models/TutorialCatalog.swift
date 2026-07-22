// TutorialCatalog.swift
// ChromaGlow — the Welcome Tour page catalog
//
// The single source of truth for the first-launch Welcome Tour: page order,
// copy, accents, and which pages a guest-only shell may see. Pure Foundation
// on purpose — no SwiftUI import — so TutorialCatalogTests can lock every
// invariant (ids, copy bounds, trademark discipline, the guest filter) without
// a MainActor or a view in sight. The view layer (WelcomeTourView) renders
// pages; the wiring layer (WelcomeTourWiring) decides when to present. Neither
// invents content.

import Foundation

/// One page of the Welcome Tour. Value type, hand-authored, never persisted —
/// the catalog below is the only place instances are made.
struct TutorialPage: Identifiable, Equatable, Sendable {
    /// Stable hand-assigned id ("tour.rooms") — locked by tests, never reused
    /// for different content.
    let id: String
    /// Uppercase mono tracked tag rendered above the title ("HOME").
    let eyebrow: String
    let title: String
    let body: String
    /// Optional quieter secondary line under the body.
    let footnote: String?
    let audience: Audience
    let illustration: Illustration
    /// Page accent as "#RRGGBB"; the view layer maps it via Color(hex:).
    let accentHex: String

    enum Audience: String, Sendable {
        case everyone
        /// Dropped on guest-only shells — mirrors MainTabView.visibleTabs,
        /// which hides the Studio tab when guestAccessInfo.isGuestOnly.
        case ownerOnly
    }

    /// One case per page; TutorialIllustrationView switches over this.
    /// Tests assert the mapping is one-to-one so no art is orphaned or reused.
    enum Illustration: String, CaseIterable, Sendable {
        case welcome, rooms, moods, roomDetail, scenes, studio,
             composer, perform, music, automations, family, everywhere, wrap
    }

    /// The catalog version this page first shipped in. Defaulted `var`, not
    /// a defaulted `let` — a defaulted `let` drops out of the memberwise
    /// init and every v1 page literal would stop compiling. Drives the
    /// "What's New" mini-tour for users who completed an older tour.
    var addedInVersion: Int = 1
}

enum TutorialCatalog {
    // Accents rotate through the app's existing identity hexes:
    // amber (HuePalette.amber), purple/teal/blue (MoreView section accents).
    private static let amber  = "#FFC107"
    private static let purple = "#8C59FF"
    private static let teal   = "#40D9BF"
    private static let blue   = "#668AFF"

    /// The full tour, in presentation order. Owners see all 12; guests see 9.
    static let pages: [TutorialPage] = [
        TutorialPage(
            id: "tour.welcome",
            eyebrow: "WELCOME",
            title: "Welcome to ChromaGlow",
            body: "Take two minutes to see everything your lights can do. Swipe through at your own pace — Skip is always in the corner if you'd rather explore on your own.",
            footnote: "You can replay this tour anytime from the More tab.",
            audience: .everyone,
            illustration: .welcome,
            accentHex: amber
        ),
        TutorialPage(
            id: "tour.rooms",
            eyebrow: "HOME",
            title: "Your rooms, one tap away",
            body: "Every room lives on the Home tab. Tap a card to switch the room on or off, slide across it to set brightness, and press and hold to wash the whole room in a color.",
            footnote: nil,
            audience: .everyone,
            illustration: .rooms,
            accentHex: amber
        ),
        TutorialPage(
            id: "tour.moods",
            eyebrow: "HOME",
            title: "Set the mood in one tap",
            body: "Energize, Read, Relax, and Sleep retune every light at once. Star the scenes you love and they wait for you right on the dashboard — and All Off is there when you head out the door.",
            footnote: "When an effect is running, a Now Playing bar appears on Home so you can stop it from anywhere.",
            audience: .everyone,
            illustration: .moods,
            accentHex: amber
        ),
        TutorialPage(
            id: "tour.roomDetail",
            eyebrow: "ROOMS",
            title: "Every light, your way",
            body: "Open a room to shape each light on its own. Copy a color from one light and paste it onto another, or arm Paint mode and tap it across as many lights as you like. Favorite shades live in My Colors — drag one straight onto a light.",
            footnote: nil,
            audience: .everyone,
            illustration: .roomDetail,
            accentHex: teal
        ),
        TutorialPage(
            id: "tour.scenes",
            eyebrow: "SCENES",
            title: "A library of looks",
            body: "Every scene lives here, grouped by room, with your starred favorites floating on top. Each card previews its real colors and motion before you play it. Copy a scene you love into another room, and give moving scenes their own pace with the speed control.",
            footnote: nil,
            audience: .everyone,
            illustration: .scenes,
            accentHex: purple
        ),
        TutorialPage(
            id: "tour.studio",
            eyebrow: "STUDIO",
            title: "Where the show begins",
            body: "Pick a room, then flip through three decks: Effects that run on the bridge itself, Live modes that react to sound, and everything you compose yourself — sixty-six built-in looks, every card previewing its real colors and motion. Tap one to start it, then tune it to taste in the mixer.",
            footnote: nil,
            audience: .ownerOnly,
            illustration: .studio,
            accentHex: amber
        ),
        TutorialPage(
            id: "tour.composer",
            eyebrow: "COMPOSER",
            title: "Compose your own light",
            body: "Layer a palette, a motion, and a reaction into a scene that's yours alone — the editor draws your Brightness Shape as a live curve, with a mic meter when sound drives it. Save it with its own icon and color, or share it as a QR code a friend can scan.",
            footnote: nil,
            audience: .ownerOnly,
            illustration: .composer,
            accentHex: purple
        ),
        TutorialPage(
            id: "tour.perform",
            eyebrow: "PERFORM",
            title: "Take the stage",
            body: "Load two looks onto decks A and B and crossfade between them as the night builds. Punch pads fire one-shot moments, and beat sync keeps every light on tempo.",
            footnote: "Own a Hue Tap Dial? Pair it in More → Physical Controls and spin it as your DJ controller.",
            audience: .ownerOnly,
            illustration: .perform,
            accentHex: blue
        ),
        TutorialPage(
            id: "tour.music",
            eyebrow: "MUSIC",
            title: "Lights that move to your music",
            body: "Pick a music source in Studio — follow along with Apple Music, or let Auto-Detect Song name whatever's playing nearby, even vinyl. Beat-synced looks lock onto the song's tempo, and one tap on the album art paints your lights in its colors.",
            footnote: "While music plays, a strip on Home shows the song and the beat — tap it anytime to switch sources.",
            audience: .ownerOnly,
            illustration: .music,
            accentHex: purple,
            addedInVersion: 2
        ),
        TutorialPage(
            id: "tour.automations",
            eyebrow: "AUTOMATE",
            title: "Light that runs itself",
            body: "Schedule wake-ups, wind-downs, and anything in between from More → Automations. Turn on All Day Scenes and your home glides from sunrise to sunset without you touching a thing.",
            footnote: nil,
            audience: .everyone,
            illustration: .automations,
            accentHex: teal
        ),
        TutorialPage(
            id: "tour.family",
            eyebrow: "PEOPLE",
            title: "Share your home",
            body: "Invite family with a QR code — each person gets their own key, never yours. Choose exactly which rooms and features they can use, and take access back just as easily.",
            footnote: nil,
            audience: .everyone,
            illustration: .family,
            accentHex: blue
        ),
        TutorialPage(
            id: "tour.everywhere",
            eyebrow: "EVERYWHERE",
            title: "Beyond the app",
            body: "Ask Siri to set a scene \"in ChromaGlow\", flip rooms from widgets and Control Center, and run your lights from your wrist — even from a watch face. The app doesn't have to be open.",
            footnote: nil,
            audience: .everyone,
            illustration: .everywhere,
            accentHex: purple
        ),
        TutorialPage(
            id: "tour.wrap",
            eyebrow: "GOOD TO KNOW",
            title: "Yours, and only yours",
            body: "Everything runs on your own network — no cloud, no account, no data collected. Light effects stay under three flashes per second and honor your system's Dim Flashing Lights setting.",
            footnote: "Replay this tour anytime from More. Want a safe place to explore? Demo Mode sets up a whole sample home.",
            audience: .everyone,
            illustration: .wrap,
            accentHex: amber
        ),
    ]

    /// The pages a given shell may present. `includeStudioSuite` is
    /// `!(guestAccessInfo.isGuestOnly && !isDemoMode)` — the exact
    /// MainTabView.visibleTabs rule, computed by the caller.
    static func pages(includeStudioSuite: Bool) -> [TutorialPage] {
        includeStudioSuite ? pages : pages.filter { $0.audience == .everyone }
    }

    /// Whether the tour should auto-present on this arrival. A pending deep
    /// link (widget/Siri/invite cold start) suppresses the tour WITHOUT
    /// marking it seen — it returns on the next clean launch.
    static func shouldAutoPresent(hasSeenTour: Bool, hasPendingDeepLink: Bool) -> Bool {
        !hasSeenTour && !hasPendingDeepLink
    }

    // MARK: - What's New (added pages for completed-tour users)

    /// Bumped when pages are ADDED, so users who completed an older tour get
    /// shown just the new ones once. v1 = the original twelve; v2 added
    /// `tour.music` (the v1.1 music integration).
    static let catalogVersion = 2

    /// The pages newer than `sinceVersion`, already audience-filtered.
    /// Empty for a guest when every new page is owner-only — the caller
    /// then presents nothing AND stamps nothing, so the check re-runs on a
    /// later launch (the device may gain owner access).
    static func whatsNewPages(sinceVersion: Int, includeStudioSuite: Bool) -> [TutorialPage] {
        pages(includeStudioSuite: includeStudioSuite)
            .filter { $0.addedInVersion > sinceVersion }
    }

    /// Whether a "What's New" mini-tour should present. Only for users who
    /// FINISHED the full tour (first-run belongs to shouldAutoPresent), with
    /// the same deep-link suppression, and only when the catalog outgrew the
    /// last version they saw. `max(1, ·)` folds legacy installs — the key
    /// didn't exist before v2, so absent (0) means "saw version 1".
    static func shouldPresentWhatsNew(hasSeenTour: Bool, lastSeenVersion: Int,
                                      hasPendingDeepLink: Bool) -> Bool {
        hasSeenTour && !hasPendingDeepLink && max(1, lastSeenVersion) < catalogVersion
    }
}
