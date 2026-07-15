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

            for text in [page.title, page.body, page.footnote].compactMap({ $0 }) {
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

    func testAccentHexParses() {
        for page in pages {
            XCTAssertNotNil(page.accentHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression),
                            "\(page.id): accent '\(page.accentHex)' is not #RRGGBB")
        }
    }

    // MARK: - Trademark + honesty discipline

    func testTrademarkDiscipline() {
        // The only permitted trademark use is the hardware name "Hue Tap Dial"
        // (nominative, matching the build-27 App-Store trademark pass).
        for page in pages {
            for text in [page.eyebrow, page.title, page.body, page.footnote].compactMap({ $0 }) {
                let stripped = text.replacingOccurrences(of: "Hue Tap Dial", with: "")
                XCTAssertFalse(stripped.contains("Hue"),
                               "\(page.id): bare 'Hue' outside 'Hue Tap Dial' in: \(text)")
                XCTAssertFalse(stripped.contains("Philips"),
                               "\(page.id): 'Philips' must not appear in tour copy: \(text)")
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

    // MARK: - Auto-present gate

    func testAutoPresentGateTruthTable() {
        XCTAssertTrue(TutorialCatalog.shouldAutoPresent(hasSeenTour: false, hasPendingDeepLink: false))
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: true, hasPendingDeepLink: false))
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: false, hasPendingDeepLink: true),
                       "a cold-start deep link owns the launch — the tour waits")
        XCTAssertFalse(TutorialCatalog.shouldAutoPresent(hasSeenTour: true, hasPendingDeepLink: true))
    }
}
