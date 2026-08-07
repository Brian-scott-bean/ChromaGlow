// Composer2RegistrationTests.swift
// ChromaGlow — Composer 2 Phase 1C3.
//
// REGISTRATION CONTRACTS ONLY. Every assertion is about the value semantics and
// the semantic boundaries of the producer registration contracts. Nothing here
// starts a runtime, constructs an orchestrator, reads a seam, or consumes a
// flag — the behavioral claims stay in the 1B1/1B2/1C1 characterization suites
// and are deliberately not restated.
//
// What this file proves:
//   • a registration is a value, and all seven fields carry identity;
//   • every registration reuses the accepted producer vocabulary rather than
//     inventing a second namespace for the nine origins;
//   • each canonical producer is described exactly once;
//   • the one producer this app cannot originate is marked as such, claims only
//     what a bridge actually reports, and implies no app lifecycle;
//   • capability sets match the audited call graph, including the places where
//     producers genuinely differ;
//   • registration encodes no precedence, no preference, and no resource
//     instance;
//   • a registration is not a consumer request;
//   • no runtime production file consumes the registration contracts.
//
// Source-shape claims here are NON-TRANSITIVE, following the 1B2/1C1/1C2
// discipline: each speaks only about the brace-matched declaration it
// extracted, never about callees. Every lookup fails hard — a missing file or
// a missing declaration is a failure, never a silent skip and never a fallback
// to a whole-file substring count. Comments AND string-literal contents are
// stripped before any token assertion, so documentation prose can neither
// satisfy nor break a guard.
//
// SCOPE OF PROOF: these are source-shape and value-semantics tests running on a
// simulator. They validate that the catalog matches the production CALL GRAPH.
// They validate no physical bridge behavior whatsoever.
//
// Determinism: no timing waits of any kind. Enforced by the last test here.

import XCTest
@testable import HueHome

@MainActor
final class Composer2RegistrationTests: XCTestCase {

    private var registrationPath: String { "HueHome/Core/Composer2Registration.swift" }

    private enum RegistrationFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
    }

    private var catalog: [Composer2ProducerRegistration] {
        Composer2ProducerRegistrationCatalog.observed
    }

    private func registration(for producer: Composer2Producer,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> Composer2ProducerRegistration {
        let matches = catalog.filter { $0.producer == producer }
        guard matches.count == 1, let only = matches.first else {
            XCTFail("expected exactly one registration for \(producer), found \(matches.count)",
                    file: file, line: line)
            throw RegistrationFailure.missingSymbol("\(producer)")
        }
        return only
    }

    /// The producers whose registration contains a given intent.
    private func producers(withIntent intent: Composer2ProducerIntent) -> Set<Composer2Producer> {
        Set(catalog.filter { $0.intents.contains(intent) }.map(\.producer))
    }

    // ──────────────────────────────────────────────
    // MARK: - Fail-hard source-shape helpers
    // ──────────────────────────────────────────────

    /// Source with comments and string-literal CONTENTS removed. A doc comment
    /// naming a forbidden token cannot fail a guard, and a quoted example
    /// cannot satisfy one.
    private func normalized(_ raw: String) -> String {
        var lines: [String] = []
        for original in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var out = ""
            var inString = false
            var escaped = false
            var pendingSlash = false
            var truncated = false
            for ch in original {
                if truncated { break }
                if escaped { escaped = false; continue }
                if inString {
                    if ch == "\\" { escaped = true; continue }
                    if ch == "\"" { inString = false }
                    continue
                }
                if ch == "\"" { inString = true; pendingSlash = false; continue }
                if ch == "/" {
                    if pendingSlash { truncated = true; continue }
                    pendingSlash = true
                    continue
                }
                if pendingSlash { out.append("/"); pendingSlash = false }
                out.append(ch)
            }
            if pendingSlash && !truncated { out.append("/") }
            lines.append(out)
        }
        return lines.joined(separator: "\n")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root
    }

    private func registrationSource(file: StaticString = #filePath,
                                    line: UInt = #line) throws -> String {
        let url = repoRoot().appendingPathComponent(registrationPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(registrationPath)", file: file, line: line)
            throw RegistrationFailure.missingFile(registrationPath)
        }
        return normalized(raw)
    }

    /// The brace-matched body of a declaration, located by an exact fragment.
    private func requireBody(_ signature: String,
                             in source: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("\(registrationPath): declaration not found: \(signature)", file: file, line: line)
            throw RegistrationFailure.missingSymbol(signature)
        }
        var depth = 0
        var started = false
        var body: [String] = []
        for current in lines[start...] {
            for ch in current {
                if ch == "{" { depth += 1; started = true }
                if ch == "}" { depth -= 1 }
            }
            if started { body.append(current) }
            if started && depth == 0 { break }
        }
        let joined = body.joined(separator: "\n")
        guard started, !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("\(registrationPath): empty body for: \(signature)", file: file, line: line)
            throw RegistrationFailure.emptyBody(signature)
        }
        return joined
    }

    private func requireDeclaration(_ fragment: String,
                                    in source: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let found = lines.first(where: { $0.contains(fragment) }),
              !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("\(registrationPath): declaration not found: \(fragment)", file: file, line: line)
            throw RegistrationFailure.missingSymbol(fragment)
        }
        return found
    }

    /// The `case` names declared directly in an extracted enum body.
    private func caseNames(in body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    }

    private func requireAbsent(_ needle: String,
                               in body: String,
                               _ what: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertFalse(body.contains(needle),
                       "\(what): did not expect \(needle)", file: file, line: line)
    }

    /// Every new declaration this packet introduces. Used by the guards so a
    /// newly added type cannot quietly escape them.
    private var newDeclarations: [String] {
        ["enum Composer2RegistrationProvenance",
         "enum Composer2ProducerIntent",
         "enum Composer2RegistrationScopeKind",
         "enum Composer2RegistrationSessionNamespace",
         "enum Composer2RegistrationStopKind",
         "struct Composer2ProducerRegistration"]
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Value semantics
    // ──────────────────────────────────────────────

    func testRegistrationEqualityAndHashingAreValueSemantics() throws {
        let composer = try registration(for: .composer)
        let rebuilt = Composer2ProducerRegistration(
            producer: composer.producer,
            provenance: composer.provenance,
            intents: composer.intents,
            scopeKinds: composer.scopeKinds,
            reachableTransports: composer.reachableTransports,
            identityBearingSessionNamespaces: composer.identityBearingSessionNamespaces,
            stopKinds: composer.stopKinds)

        XCTAssertEqual(composer, rebuilt, "a registration is a value, not a reference")
        XCTAssertEqual(composer.hashValue, rebuilt.hashValue)
        XCTAssertEqual(Set([composer, rebuilt]).count, 1, "equal registrations collapse to one")

        XCTAssertNotEqual(composer, try registration(for: .studio))
        XCTAssertEqual(Set(catalog).count, catalog.count,
                       "no two catalog entries may be equal")
    }

    /// All seven fields participate in identity — none is decorative.
    func testRegistrationsDifferingInASingleFieldAreDistinct() throws {
        let base = try registration(for: .widget)

        func mutate(
            producer: Composer2Producer? = nil,
            provenance: Composer2RegistrationProvenance? = nil,
            intents: Set<Composer2ProducerIntent>? = nil,
            scopeKinds: Set<Composer2RegistrationScopeKind>? = nil,
            transports: Set<Composer2Transport>? = nil,
            sessions: Set<Composer2RegistrationSessionNamespace>? = nil,
            stops: Set<Composer2RegistrationStopKind>? = nil
        ) -> Composer2ProducerRegistration {
            Composer2ProducerRegistration(
                producer: producer ?? base.producer,
                provenance: provenance ?? base.provenance,
                intents: intents ?? base.intents,
                scopeKinds: scopeKinds ?? base.scopeKinds,
                reachableTransports: transports ?? base.reachableTransports,
                identityBearingSessionNamespaces: sessions ?? base.identityBearingSessionNamespaces,
                stopKinds: stops ?? base.stopKinds)
        }

        let variants = [
            mutate(producer: .watch),
            mutate(provenance: .observedExternally),
            mutate(intents: base.intents.union([.continuousStreaming])),
            mutate(scopeKinds: base.scopeKinds.subtracting([.zone])),
            mutate(transports: base.reachableTransports.union([.entertainment])),
            mutate(sessions: [.entertainment]),
            mutate(stops: [.everything]),
        ]
        XCTAssertEqual(variants.count, 7, "one variant per field")
        for variant in variants {
            XCTAssertNotEqual(base, variant, "every field must carry identity")
        }
        XCTAssertEqual(Set(variants + [base]).count, 8, "all eight values are distinct")
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Identity reuse
    // ──────────────────────────────────────────────

    func testCatalogCoversTheAcceptedProducerVocabularyExactly() {
        let registered = Set(catalog.map(\.producer))
        XCTAssertEqual(registered, Set(Composer2Producer.allCases),
                       "the catalog describes the accepted vocabulary, no more and no less")
        XCTAssertEqual(Composer2Producer.allCases.count, 9,
                       "nine canonical producers after the 1C2-a correction")
    }

    /// Registration reuses `Composer2Producer` and introduces no second
    /// namespace for the nine origins.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted declarations.
    func testRegistrationIntroducesNoSecondProducerIdentity() throws {
        let src = try registrationSource()

        for invented in ["ProducerID", "OwnerID", "RegistrationID", "ProducerKind",
                         "SourceKind", "ControlSource", "rawValue"] {
            requireAbsent(invented, in: src,
                          "registration must not create a second producer namespace")
        }

        let body = try requireBody("struct Composer2ProducerRegistration", in: src)
        XCTAssertTrue(body.contains("let producer: Composer2Producer"),
                      "the registration must reference the accepted producer identity directly")
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Catalog shape
    // ──────────────────────────────────────────────

    func testEveryCanonicalProducerIsRegisteredExactlyOnce() {
        XCTAssertEqual(catalog.count, 9, "one registration per canonical producer")

        var seen: [Composer2Producer: Int] = [:]
        for entry in catalog { seen[entry.producer, default: 0] += 1 }

        for producer in Composer2Producer.allCases {
            XCTAssertEqual(seen[producer], 1,
                           "\(producer) must be registered exactly once, was \(seen[producer] ?? 0)")
        }
    }

    /// The catalog is pure data: it performs no work and owns no mutable state.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted catalog body.
    func testTheCatalogIsImmutablePureData() throws {
        let src = try registrationSource()
        let body = try requireBody("enum Composer2ProducerRegistrationCatalog", in: src)

        XCTAssertTrue(body.contains("static let observed"),
                      "the catalog exposes exactly one immutable declaration")
        for mutable in ["static var", "var ", "func ", "init(", "mutating", "lazy"] {
            requireAbsent(mutable, in: body,
                          "the catalog is immutable data and performs no work")
        }
        XCTAssertFalse(caseNames(in: body).contains(where: { !$0.isEmpty }),
                       "the catalog namespace declares no cases, so it cannot be instantiated")
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Provenance and the observed producer
    // ──────────────────────────────────────────────

    func testOnlyForeignControllerIsRegisteredAsObservedExternally() {
        let observed = catalog.filter { $0.provenance == .observedExternally }.map(\.producer)
        XCTAssertEqual(observed, [.foreignController],
                       "exactly one producer is not originated by this app")

        let inApp = Set(catalog.filter { $0.provenance == .originatedInApp }.map(\.producer))
        XCTAssertEqual(inApp.count, 8)
        XCTAssertFalse(inApp.contains(.foreignController))
    }

    /// The bridge tells us an active configuration and nothing else — no room,
    /// no vendor, no name. The registration claims exactly that much.
    func testForeignControllerRegistersOnlyWhatTheBridgeReportsAndNoStop() throws {
        let foreign = try registration(for: .foreignController)

        XCTAssertEqual(foreign.intents, [.continuousStreaming])
        XCTAssertEqual(foreign.scopeKinds, [.identifiedBridge],
                       "the bridge reports no room and no zone for a third-party session")
        XCTAssertEqual(foreign.reachableTransports, [.entertainment])
        XCTAssertEqual(foreign.identityBearingSessionNamespaces, [.entertainment])
        XCTAssertTrue(foreign.stopKinds.isEmpty,
                      "an observed controller issues no stop to us")

        XCTAssertFalse(foreign.scopeKinds.contains(.room))
        XCTAssertFalse(foreign.scopeKinds.contains(.zone))
        XCTAssertFalse(foreign.scopeKinds.contains(.wholeSystem))
    }

    /// Nothing in the contract implies the app can construct, start, retain, or
    /// tear down a producer it merely observes.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted declarations.
    func testNoRegistrationImpliesAnAppLifecycleForAnObservedProducer() throws {
        let src = try registrationSource()

        for declaration in newDeclarations {
            let body = try requireBody(declaration, in: src)
            for lifecycle in ["start", "register(", "lifecycle", "retain",
                              "refcount", "release", "deinit", "teardown"] {
                requireAbsent(lifecycle, in: body,
                              "\(declaration) must imply no lifecycle")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - E. Evidence-backed capability sets
    // ──────────────────────────────────────────────

    /// All-Day sweeps the room list and never reads the zone list.
    func testAllDayRegistersRoomScopeButNotZoneScope() throws {
        let allDay = try registration(for: .allDay)

        XCTAssertTrue(allDay.scopeKinds.contains(.room))
        XCTAssertFalse(allDay.scopeKinds.contains(.zone),
                       "All-Day never reads the zone list, so it cannot address one")
        XCTAssertEqual(allDay.intents, [.groupState])
        XCTAssertEqual(allDay.reachableTransports, [.rest])
        XCTAssertEqual(allDay.stopKinds, [.everything],
                       "All-Day has no per-room and no per-bridge stop")
    }

    /// Automation's bulk writer walks rooms only and requires a resolved
    /// client, so its addressable scope is narrower than any other in-app
    /// origin's.
    func testAutomationScopeIsNarrowerThanEveryOtherInAppProducer() throws {
        let automation = try registration(for: .automation)

        XCTAssertTrue(automation.scopeKinds.contains(.room))
        XCTAssertTrue(automation.scopeKinds.contains(.wholeSystem))
        XCTAssertFalse(automation.scopeKinds.contains(.zone),
                       "the bulk writer walks the room map only")
        XCTAssertFalse(automation.scopeKinds.contains(.unidentifiedBridge),
                       "the bulk writer requires a resolved client per bridge")

        for other in catalog where other.provenance == .originatedInApp
                                && other.producer != .automation
                                && other.producer != .allDay {
            XCTAssertTrue(other.scopeKinds.contains(.unidentifiedBridge),
                          "\(other.producer) addresses an unidentified bridge; automation does not")
        }
    }

    /// The 1C2-a correction is present and is genuinely its own origin.
    func testAutomationIsRegisteredAndDistinctFromManualAndAllDay() throws {
        let automation = try registration(for: .automation)
        let manual = try registration(for: .manual)
        let allDay = try registration(for: .allDay)

        XCTAssertNotEqual(automation, manual)
        XCTAssertNotEqual(automation, allDay)

        XCTAssertTrue(automation.intents.contains(.bridgeFirmwareEffect),
                      "the automation effect path activates a firmware effect")
        XCTAssertFalse(manual.intents.contains(.bridgeFirmwareEffect),
                       "no manual surface activates a firmware effect")
        XCTAssertFalse(allDay.intents.contains(.bridgeFirmwareEffect))

        XCTAssertTrue(automation.stopKinds.isEmpty,
                      "neither automation executor contains a stop")
        XCTAssertFalse(manual.stopKinds.isEmpty,
                       "manual surfaces do stop things")
    }

    func testContinuousStreamingIsRegisteredOnlyByComposerStudioSiriAndForeignController() {
        XCTAssertEqual(producers(withIntent: .continuousStreaming),
                       [.composer, .studio, .siri, .foreignController],
                       "two in-app streamers, one delegating origin, one observed streamer")

        for producer in [Composer2Producer.allDay, .automation, .widget, .watch, .manual] {
            XCTAssertFalse(producers(withIntent: .continuousStreaming).contains(producer),
                           "\(producer) reaches no streaming path")
        }
    }

    /// Siri reaches a firmware-effect ACTIVATION by delegation, so it registers
    /// the capability.
    ///
    /// Evidence: the Siri effect choice list includes `candle`; the intent parks
    /// a pending action; the Studio surface drains it into the same `apply`
    /// funnel a tap uses; and `candle`'s strategy is bridge-native. The
    /// delegated firmware reach and the delegated streaming reach are the same
    /// kind of fact and are registered the same way — registering one and not
    /// the other would contradict the contract.
    ///
    /// Siri's direct `no_effect` write is a CLEAR and is not evidence of
    /// activation; it is represented by the stop set instead.
    func testSiriRegistersFirmwareEffectActivationReachedThroughStudio() throws {
        let siri = try registration(for: .siri)

        XCTAssertTrue(siri.intents.contains(.bridgeFirmwareEffect),
                      "a Siri-originated Studio effect activates a bridge-native effect")
        XCTAssertTrue(siri.intents.contains(.continuousStreaming),
                      "the same delegation reaches the streaming engines")
        XCTAssertTrue(siri.reachableTransports.contains(.entertainment),
                      "delegated reach counts for transports too")

        // Both delegated reaches are treated identically — no asymmetry.
        let studio = try registration(for: .studio)
        for delegated: Composer2ProducerIntent in [.bridgeFirmwareEffect, .continuousStreaming] {
            XCTAssertTrue(studio.intents.contains(delegated),
                          "the executing origin registers \(delegated)")
            XCTAssertTrue(siri.intents.contains(delegated),
                          "the delegating origin registers \(delegated) too")
        }

        XCTAssertEqual(siri.stopKinds, [.everything],
                       "the whole-home clear is Siri's stop capability")
    }

    /// Only Studio reaches a bridge-stored PLAYBACK path.
    ///
    /// The claim rests on the save path reaching an activation call — the
    /// bridge is told to begin running the uploaded chain — not on the mere
    /// existence of a save action. Uploading a program the bridge never runs
    /// would be a save, not playback, and would not earn this case.
    ///
    /// This is a claim about the production CALL GRAPH. It asserts nothing
    /// about physical bridge behavior.
    func testBridgeStoredPlaybackIsRegisteredOnlyByStudio() throws {
        XCTAssertEqual(producers(withIntent: .bridgeStoredPlayback), [.studio])

        let studio = try registration(for: .studio)
        XCTAssertTrue(studio.reachableTransports.contains(.bridgeStored),
                      "the playback intent and its transport travel together")

        for entry in catalog where entry.producer != .studio {
            XCTAssertFalse(entry.reachableTransports.contains(.bridgeStored),
                           "\(entry.producer) reaches no bridge-stored playback")
            XCTAssertFalse(entry.intents.contains(.bridgeStoredPlayback))
        }

        let composer = try registration(for: .composer)
        XCTAssertFalse(composer.intents.contains(.bridgeStoredPlayback),
                       "Composer's bridge-stored arm is unreachable on today's call graph")
    }

    func testSceneRecallIsRegisteredExactlyByWidgetSiriWatchAndManual() {
        XCTAssertEqual(producers(withIntent: .sceneRecall),
                       [.widget, .siri, .watch, .manual])
    }

    /// The REST telemetry namespace has exactly one representation in
    /// production, and every session it holds belongs to Composer. A mailbox
    /// scope tagged with an owner is scheduling ownership, not a session.
    func testRestTelemetryIdentityIsExactlyComposer() {
        let bearers = Set(catalog
            .filter { $0.identityBearingSessionNamespaces.contains(.restTelemetry) }
            .map(\.producer))

        XCTAssertEqual(bearers, [.composer],
                       "only Composer has a REST telemetry session; the others have mailbox keys")
    }

    /// Most origins write light state today while participating in no session
    /// at all.
    func testOnlyComposerStudioAndForeignControllerBearSessionIdentity() {
        let bearers = Set(catalog
            .filter { !$0.identityBearingSessionNamespaces.isEmpty }
            .map(\.producer))

        XCTAssertEqual(bearers, [.composer, .studio, .foreignController])

        for producer in [Composer2Producer.allDay, .automation, .widget,
                         .siri, .watch, .manual] {
            XCTAssertFalse(bearers.contains(producer),
                           "\(producer) bears no session identity")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - F. Stop shapes
    // ──────────────────────────────────────────────

    /// A Composer stop always names an exact bridge and room. A nil bridge
    /// there is the bridgeless identity inside an exact scope, NOT a request to
    /// find whichever bridge hosts the group.
    func testComposerStopKindsAreExactlyExactScope() throws {
        let composer = try registration(for: .composer)

        XCTAssertEqual(composer.stopKinds, [.exactScope])
        XCTAssertFalse(composer.stopKinds.contains(.anyBridgeHosting),
                       "a bridgeless exact scope is not an any-bridge request")
        XCTAssertFalse(composer.stopKinds.contains(.everything))
    }

    func testOnlyManualRegistersAnyBridgeHostingStop() {
        let anyBridge = Set(catalog
            .filter { $0.stopKinds.contains(.anyBridgeHosting) }
            .map(\.producer))

        XCTAssertEqual(anyBridge, [.manual],
                       "one compatibility path expresses the any-bridge stop")
    }

    func testWidgetWatchAutomationAndForeignControllerRegisterNoStop() throws {
        for producer in [Composer2Producer.widget, .watch, .automation, .foreignController] {
            XCTAssertTrue(try registration(for: producer).stopKinds.isEmpty,
                          "\(producer) expresses no stop")
        }
        for producer in [Composer2Producer.composer, .studio, .allDay, .siri, .manual] {
            XCTAssertFalse(try registration(for: producer).stopKinds.isEmpty,
                           "\(producer) does express a stop")
        }
    }

    /// A delegated transport is reachable, yet the identity does not survive
    /// the handoff that reaches it.
    func testSiriReachesEntertainmentYetBearsNoSessionIdentity() throws {
        let siri = try registration(for: .siri)

        XCTAssertTrue(siri.reachableTransports.contains(.entertainment))
        XCTAssertTrue(siri.identityBearingSessionNamespaces.isEmpty,
                      "the resulting session records the executing origin, never Siri")

        let studio = try registration(for: .studio)
        XCTAssertTrue(studio.identityBearingSessionNamespaces.contains(.entertainment),
                      "the executing origin is the one the session preserves")
    }

    // ──────────────────────────────────────────────
    // MARK: - G. Policy neutrality
    // ──────────────────────────────────────────────

    /// NON-TRANSITIVE: speaks only about the extracted declarations.
    func testRegistrationEncodesNoPrecedenceOrPriority() throws {
        let src = try registrationSource()

        for declaration in newDeclarations {
            let body = try requireBody(declaration, in: src)
            for ranking in ["priority", "rank", "wins", "beats", "outrank", "precede",
                            "exclusive", "dominant", "owner", "preferred",
                            "canTakeOver", "mayOverride", "Comparable"] {
                requireAbsent(ranking, in: body,
                              "\(declaration) carries no precedence")
            }
        }
    }

    func testNoRegistrationTypeDeclaresComparable() throws {
        let src = try registrationSource()
        for declaration in newDeclarations {
            let line = try requireDeclaration(declaration, in: src)
            requireAbsent("Comparable", in: line, "\(declaration) is not ordered")
        }
        requireAbsent(": Comparable", in: src, "no conformance anywhere in the file")
        requireAbsent("static func <", in: src, "no ordering operator")
    }

    /// Transport support is descriptive. It carries no preference, no ordering,
    /// no fallback chain, and no "automatic" case.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted registration struct,
    /// which is where the transport field is declared.
    func testTransportSupportCarriesNoPreferenceSemantics() throws {
        let src = try registrationSource()
        let body = try requireBody("struct Composer2ProducerRegistration", in: src)

        XCTAssertTrue(body.contains("let reachableTransports: Set<Composer2Transport>"),
                      "transports reuse the accepted vocabulary as an unordered set")
        for preference in ["auto", "prefer", "fallback", "ordered", "default",
                           "first", "Array<Composer2Transport>", "[Composer2Transport]"] {
            requireAbsent(preference, in: body,
                          "transport support states no preference and no order")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - H. No resource instances
    // ──────────────────────────────────────────────

    /// A static capability catalog must not name live resources.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted declarations.
    func testRegistrationEncodesNoRoomBridgeOrConfigurationInstance() throws {
        let src = try registrationSource()

        for declaration in newDeclarations {
            let body = try requireBody(declaration, in: src)
            for identity in ["Composer2GroupScope", "Composer2GroupIdentity",
                             "Composer2BridgeIdentity", "Composer2ConfigurationIdentity",
                             "Composer2SessionIdentity", "Composer2Counter",
                             "roomID", "bridgeID", "configID"] {
                requireAbsent(identity, in: body,
                              "\(declaration) must not carry a resource instance")
            }
        }

        let catalogBody = try requireBody("enum Composer2ProducerRegistrationCatalog", in: src)
        requireAbsent("String", in: catalogBody,
                      "the catalog holds no identifiers of any kind")
    }

    /// Kinds, not instances: no scope, stop, or session case carries a payload.
    func testEveryScopeStopAndSessionCaseIsPayloadFree() throws {
        let src = try registrationSource()

        for declaration in ["enum Composer2RegistrationScopeKind",
                            "enum Composer2RegistrationStopKind",
                            "enum Composer2RegistrationSessionNamespace",
                            "enum Composer2ProducerIntent",
                            "enum Composer2RegistrationProvenance"] {
            let body = try requireBody(declaration, in: src)
            let names = caseNames(in: body)
            XCTAssertFalse(names.isEmpty, "\(declaration) must declare cases")
            for name in names {
                XCTAssertFalse(name.contains("("),
                               "\(declaration).\(name) must carry no associated value")
            }
        }

        XCTAssertEqual(Composer2RegistrationScopeKind.allCases.count, 5)
        XCTAssertEqual(Composer2RegistrationStopKind.allCases.count, 3)
        XCTAssertEqual(Composer2RegistrationSessionNamespace.allCases.count, 2)
        XCTAssertEqual(Composer2ProducerIntent.allCases.count, 6)
        XCTAssertEqual(Composer2RegistrationProvenance.allCases.count, 2)
    }

    // ──────────────────────────────────────────────
    // MARK: - I. Structural guards
    // ──────────────────────────────────────────────

    /// A pure value file, and not a consumer request.
    func testRegistrationSourceHasNoUIRuntimeNetworkingOrGlobalState() throws {
        let src = try registrationSource()

        XCTAssertFalse(src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty read proves nothing")
        XCTAssertTrue(src.contains("struct Composer2ProducerRegistration"),
                      "the registration file was read")
        XCTAssertTrue(src.contains("enum Composer2ProducerRegistrationCatalog"),
                      "the catalog was read")

        for forbidden in ["import ", "SwiftUI", "UIKit", "URLSession", "BridgeAPIClient",
                          "HueEntertainmentClient", "Task", "actor ", "class ",
                          "UserDefaults", "Keychain", "DispatchQueue", "NotificationCenter",
                          "static var", "shared", "@escaping", "->", "Codable",
                          "os_log", "print("] {
            requireAbsent(forbidden, in: src, "the registration contract is a pure value file")
        }

        // A registration describes a producer. It is not a typed consumer
        // request, and none of the resolver-context fields may appear.
        for consumerField in ["target:", "requestedTransport", "generation",
                              "contender", "currentOwner", "payload", "action"] {
            requireAbsent(consumerField, in: src,
                          "registration is not a consumer request")
        }
    }

    /// No RUNTIME production file consumes the registration contracts. The only
    /// production sources naming them are the two FOUNDATION declaration files:
    /// this packet's own, and the Phase 1C4 consumer contracts, which reuse
    /// `Composer2ProducerIntent` rather than declaring a second operation
    /// vocabulary.
    ///
    /// The allowlist is pinned to exact filenames — deliberately not a
    /// directory-wide rule — and every allowlisted file must actually be
    /// visited, so an entry naming a file the walk never sees would weaken the
    /// guard without failing it.
    func testNoProductionCodeConsumesTheRegistrationTypes() throws {
        let registrationTypes = [
            "Composer2RegistrationProvenance", "Composer2ProducerIntent",
            "Composer2RegistrationScopeKind", "Composer2RegistrationSessionNamespace",
            "Composer2RegistrationStopKind", "Composer2ProducerRegistration",
            "Composer2ProducerRegistrationCatalog"
        ]
        // Deliberately NOT the substring "Composer2": the registration file's
        // legitimate use of the accepted 1C2 vocabulary must not trip this.
        let definitionFile = "Composer2Registration.swift"
        let consumerContractsFile = "Composer2ConsumerContracts.swift"
        let foundationFiles: Set<String> = [definitionFile, consumerContractsFile]
        XCTAssertEqual(foundationFiles.count, 2,
                       "the allowlist is exactly the two foundation files")

        let productionRoot = repoRoot().appendingPathComponent("HueHome")
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: productionRoot.path,
                                                        isDirectory: &isDirectory)
        XCTAssertTrue(rootExists && isDirectory.boolValue,
                      "production-source root must resolve; the scan is the proof")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: productionRoot, includingPropertiesForKeys: nil))
        var scannedCount = 0
        var definitionSource: String?
        var sawConsumerContractsFile = false
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            scannedCount += 1
            guard !foundationFiles.contains(url.lastPathComponent) else {
                if url.lastPathComponent == definitionFile { definitionSource = source }
                if url.lastPathComponent == consumerContractsFile { sawConsumerContractsFile = true }
                continue
            }
            for type in registrationTypes where source.contains(type) {
                offenders.append("\(url.lastPathComponent): \(type)")
            }
        }

        XCTAssertGreaterThan(scannedCount, 0,
                             "an empty scan proves nothing — the walk must cover sources")
        let definition = try XCTUnwrap(definitionSource,
                                       "the scan must have visited the registration file itself")
        XCTAssertTrue(sawConsumerContractsFile,
                      "the allowlisted consumer-contracts file must exist and be scanned, "
                      + "or the allowlist is silently weakening this guard")
        for type in registrationTypes {
            XCTAssertTrue(definition.contains(type),
                          "\(type) must exist in the registration file, or this guard is stale")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "no runtime consumer is authorized through Phase 1C4: \(offenders)")
    }

    // ──────────────────────────────────────────────
    // MARK: - J. Determinism self-guard
    // ──────────────────────────────────────────────

    /// No hardening guard covers a newly added test file, so this file polices
    /// its own determinism. The forbidden tokens are assembled at runtime from
    /// fragments, and the scan runs over source with comments and string
    /// literals removed — so this test cannot match its own guard text.
    func testThisFileUsesNoTimingWaits() throws {
        let raw = try XCTUnwrap(try? String(contentsOfFile: #filePath, encoding: .utf8),
                                "could not read this test file")

        var stripped: [String] = []
        for original in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(original)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var out = ""
            var inString = false
            var escaped = false
            for ch in text {
                if escaped { escaped = false; continue }
                if ch == "\\" && inString { escaped = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                if !inString { out.append(ch) }
            }
            stripped.append(out)
        }
        let scanned = stripped.joined(separator: "\n")

        let forbidden = ["Task" + "." + "sleep",
                         "XCT" + "Waiter",
                         "wait" + "(for:",
                         "expect" + "ation("]
        for token in forbidden {
            XCTAssertFalse(scanned.contains(token),
                           "this file must contain no timing wait — found: \(token)")
        }
    }
}
