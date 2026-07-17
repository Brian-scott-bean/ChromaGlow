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
             composer, perform, automations, family, everywhere, wrap
    }
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
            body: "Every scene lives here, grouped by room, with your starred favorites floating on top. Copy a scene you love into another room, and give moving scenes their own pace with the speed control.",
            footnote: nil,
            audience: .everyone,
            illustration: .scenes,
            accentHex: purple
        ),
        TutorialPage(
            id: "tour.studio",
            eyebrow: "STUDIO",
            title: "Where the show begins",
            body: "Pick a room, then flip through three decks: Effects that run on the bridge itself, Live modes that listen and react to sound, and everything you compose yourself. Tap a card to start it, then open the mixer and tune it to taste.",
            footnote: nil,
            audience: .ownerOnly,
            illustration: .studio,
            accentHex: amber
        ),
        TutorialPage(
            id: "tour.composer",
            eyebrow: "COMPOSER",
            title: "Compose your own light",
            body: "Layer a palette, a motion, and a reaction into a scene that's yours alone, then save it with its own icon and color. Share it as a QR code — a friend scans it and the scene plays on their lights.",
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
}
