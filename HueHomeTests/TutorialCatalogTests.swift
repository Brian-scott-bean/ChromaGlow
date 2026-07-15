// TutorialCatalogTests.swift
// ChromaGlow — invariants for the Welcome Tour page catalog
//
// The tour's copy and structure are data (TutorialCatalog), so the quality
// bar is a test suite, exactly like PresetCatalogTests locks the built-in
// presets. Anything that would make a page render wrong, read wrong, or leak
// a trademark fails here before it ever reaches a device.

import XCTest
@testable import HueHome

final class TutorialCatalogTests: XCTestCase {

    private let pages = TutorialCatalog.pages

    // MARK: - Structure

    func testCatalogHasTwelvePagesBookendedForEveryone() {
        XCTAssertEqual(pages.count, 12)
        XCTAssertEqual(pages.first?.id, "tour.welcome")
        XCTAssertEqual(pages.last?.id, "tour.wrap")
        // Guests must always get a proper opening and closing.
        XCTAssertEqual(pages.first?.audience, .everyone)
        XCTAssertEqual(pages.last?.audience, .everyone)
    }

    func testPageOrderIsThePedagogicalArc() {
        // The tour teaches in tab order, basics before power features, with
        // the owner-only Studio suite contiguous. A shuffle is a regression.
        XCTAssertEqual(pages.map(\.id), [
            "tour.welcome", "tour.rooms", "tour.moods", "tour.roomDetail",
            "tour.scenes", "tour.studio", "tour.composer", "tour.perform",
            "tour.automations", "tour.family", "tour.everywhere", "tour.wrap",
        ])
    }

    func testEveryPageHasAUniqueStableID() {
        let ids = pages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate page ids")
        for id in ids {
            XCTAssertTrue(id.hasPrefix("tour."), "id '\(id)' must be namespaced 'tour.'")
            XCTAssertGreaterThan(id.count, "tour.".count, "id '\(id)' has no name")
        }
    }

    func testIllustrationsAreOneToOne() {
        let used = pages.map(\.illustration)
        XCTAssertEqual(Set(used).count, used.count, "an illustration is reused")
        XCTAssertEqual(Set(used), Set(TutorialPage.Illustration.allCases),
                       "every illustration case must back exactly one page")
    }

    // MARK: - Copy quality bounds

    func testTitlesAndBodiesAreBounded() {
        var seenTitles = Set<String>()
        for page in pages {
            XCTAssertFalse(page.title.isEmpty, "\(page.id): empty title")
            XCTAssertLessThanOrEqual(page.title.count, 36,
                                     "\(page.id): title too long to sit on one line at large Dynamic Type")
            XCTAssertTrue(seenTitles.insert(page.title).inserted, "\(page.id): duplicate title")

            XCTAssertGreaterThanOrEqual(page.body.count, 40, "\(page.id): body too thin to teach anything")
            XCTAssertLessThanOrEqual(page.body.count, 300, "\(page.id): body too long for one tour page")

            if let footnote = page.footnote {
                XCTAssertGreaterThanOrEqual(footnote.count, 10, "\(page.id): footnote too thin")
                XCTAssertLessThanOrEqual(footnote.count, 160, "\(page.id): footnote too long")
            }

            for text in [page.eyebrow, page.title, page.body, page.footnote].compactMap({ $0 }) {
                XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines),
                               "\(page.id): stray leading/trailing whitespace")
            }
        }
    }

    func testEyebrowsAreUppercaseTags() {
        for page in pages {
            XCTAssertFalse(page.eyebrow.isEmpty, "\(page.id): empty eyebrow")
            XCTAssertEqual(page.eyebrow, page.eyebrow.uppercased(),
                           "\(page.id): eyebrow renders in the tracked mono tag — must be uppercase")
            XCTAssertLessThanOrEqual(page.eyebrow.count, 26, "\(page.id): eyebrow too long for the tag")
        }
    }

    func testAccentsAreTheFourIdentityHexes() {
        // Amber = HuePalette.amber; purple/teal/blue = MoreView's section
        // accents. Off-brand or typo'd hexes fail here, not on device.
        let identity: Set<String> = ["#FFC107", "#8C59FF", "#40D9BF", "#668AFF"]
        for page in pages {
            XCTAssertNotNil(page.accentHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression),
                            "\(page.id): accent '\(page.accentHex)' is not #RRGGBB")
            XCTAssertTrue(identity.contains(page.accentHex),
                          "\(page.id): accent '\(page.accentHex)' is not an identity color")
        }
    }

    // MARK: - Trademark + honesty discipline

    func testTrademarkDiscipline() {
        // The only permitted trademark use is the hardware name "Hue Tap Dial"
        // (nominative, matching the build-27 App-Store trademark pass).
        // Case-insensitive: eyebrows are FORCED uppercase, so "HUE ..." is the
        // natural leak form there and a case-sensitive check would miss it.
        for page in pages {
            for text in [page.eyebrow, page.title, page.body, page.footnote].compactMap({ $0 }) {
                let stripped = text
                    .replacingOccurrences(of: "Hue Tap Dial", with: "", options: .caseInsensitive)
                    .lowercased()
                XCTAssertFalse(stripped.contains("hue"),
                               "\(page.id): bare 'Hue' outside 'Hue Tap Dial' in: \(text)")
                XCTAssertFalse(stripped.contains("philips"),
                               "\(page.id): 'Philips' must not appear in tour copy: \(text)")
            }
        }
    }

    func testGuestVisibleCopyNeverMentionsTheStudioSuite() {
        // The audience filter drops the owner-only PAGES; this pins the finer
        // rule that no guest-visible page's copy references those features.
        for page in pages where page.audience == .everyone {
            for text in [page.eyebrow, page.title, page.body, page.footnote].compactMap({ $0 }) {
                let lower = text.lowercased()
                for banned in ["studio", "composer", "perform"] {
                    XCTAssertFalse(lower.contains(banned),
                                   "\(page.id): guest-visible copy mentions '\(banned)': \(text)")
                }
            }
        }
    }

    func testCopyNeverClaimsHardwarePresence() {
        // The tour also runs in demo mode with zero real hardware — copy must
        // never assert a live connection.
        for page in pages {
            for text in [page.body, page.footnote].compactMap({ $0 }) {
                XCTAssertFalse(text.contains("is connected"), "\(page.id): claims hardware presence")
                XCTAssertFalse(text.contains("are connected"), "\(page.id): claims hardware presence")
            }
        }
    }

    // MARK: - Guest filtering

    func testStudioSuiteIsOwnerOnlyAndNothingElseIs() {
        let ownerOnly = Set(pages.filter { $0.audience == .ownerOnly }.map(\.id))
        XCTAssertEqual(ownerOnly, ["tour.studio", "tour.composer", "tour.perform"],
                       "exactly the Studio suite mirrors the hidden guest Studio tab")
    }

    func testGuestFilterPreservesOrderAndDropsExactlyTheStudioSuite() {
        let guestPages = TutorialCatalog.pages(includeStudioSuite: false)
        XCTAssertEqual(guestPages, pages.filter { $0.audience == .everyone },
                       "guest filter must be the .everyone subsequence in original order")
        XCTAssertEqual(guestPages.count, pages.count - 3)
        XCTAssertEqual(TutorialCatalog.pages(includeStudioSuite: true), pages)
    }

    // MARK: - Motion math (the illustrations are pure functions of time)

    func testTourMotionMathIsBoundedForAllInputs() {
        let times: [Double] = [-7.3, -1, 0, 0.4, 1.9, 12.5, 1_000.25, 8e8]
        for t in times {
            for period in [0.75, 2.0, 6.0, 12.0] {
                let w = TourMotionMath.wrap(t, period: period)
                XCTAssertTrue(w >= 0 && w < 1, "wrap(\(t), \(period)) = \(w) out of [0,1)")
                let p = TourMotionMath.pulse(t, period: period)
                XCTAssertTrue(p >= 0 && p <= 1, "pulse(\(t), \(period)) = \(p) out of [0,1]")
                let h = TourMotionMath.hop(t, count: 4, period: period)
                XCTAssertTrue((0..<4).contains(h), "hop(\(t)) = \(h) out of range")
            }
            let e = TourMotionMath.ease(t)
            XCTAssertTrue(e >= 0 && e <= 1, "ease(\(t)) = \(e) out of [0,1]")
            for (from, to) in [(0.2, 0.6), (0.5, 0.5), (0.8, 0.2), (0.0, 1.0)] {
                let s = TourMotionMath.segment(t, from: from, to: to)
                XCTAssertTrue(s >= 0 && s <= 1, "segment(\(t), \(from), \(to)) = \(s) out of [0,1]")
            }
        }
        // Degenerate inputs must not trap.
        XCTAssertEqual(TourMotionMath.wrap(5, period: 0), 0)
        XCTAssertEqual(TourMotionMath.pulse(5, period: 0), 0)
        XCTAssertEqual(TourMotionMath.hop(5, count: 0, period: 1), 0)
        // Zero-width and inverted slices degrade to a step at `to`.
        XCTAssertEqual(TourMotionMath.segment(0.4, from: 0.5, to: 0.5), 0)
        XCTAssertEqual(TourMotionMath.segment(0.6, from: 0.5, to: 0.5), 1)
        XCTAssertEqual(TourMotionMath.segment(0.1, from: 0.8, to: 0.2), 0)
        XCTAssertEqual(TourMotionMath.segment(0.9, from: 0.8, to: 0.2), 1)
    }

    func testTourNeverCyclesFasterThanTheFlashCap() {
        // tour.wrap's SHIPPED copy promises "under three flashes per second";
        // every illustration cycle is >= this named floor. 1/0.75s ≈ 1.33Hz,
        // comfortably under the WCAG/App-Store 3Hz line.
        XCTAssertGreaterThanOrEqual(TourMotionMath.fastestAllowedPeriod, 1.0 / 3.0)
        XCTAssertEqual(TourMotionMath.fastestAllowedPeriod, 0.75, accuracy: 1e-9)
    }

    func testTourMotionMathIsPeriodic() {
        for t in [0.0, 1.3, 7.77] {
            XCTAssertEqual(TourMotionMath.wrap(t, period: 3), TourMotionMath.wrap(t + 3, period: 3),
                           accuracy: 1e-9)
            XCTAssertEqual(TourMotionMath.pulse(t, period: 3), TourMotionMath.pulse(t + 3, period: 3),
                           accuracy: 1e-9)
        }
        // segment covers its slice monotonically: 0 before, 1 after.
        XCTAssertEqual(TourMotionMath.segment(0.0, from: 0.2, to: 0.6), 0)
        XCTAssertEqual(TourMotionMath.segment(1.0, from: 0.2, to: 0.6), 1)
        XCTAssertEqual(TourMotionMath.segment(0.4, from: 0.2, to: 0.6), 0.5, accuracy: 1e-9)
    }

    // MARK: - Auto-present gate

    func testAutoPresentGateTruthTable() {
        XCTAssertTrue(TutorialCatalog.shouldAutoPresent(hasSeenTour: false, hasPendingDeepLink: false))
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: true, hasPendingDeepLink: false))
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: false, hasPendingDeepLink: true),
                       "a cold-start deep link owns the launch — the tour waits")
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: true, hasPendingDeepLink: true))
    }
}
