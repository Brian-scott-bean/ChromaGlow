// Composer2ResolverTests.swift
// ChromaGlow — Tests
//
// Composer 2 Phase 1D: the pure resolver seam.
//
// Every test here is deterministic and hermetic: no bridge, no simulator
// timing, no network, no storage, no waiting. The resolver is a function, so
// the suite is a truth table plus a set of source-shape guards proving the
// function stayed a function.
//
// Source-shape claims are explicitly NON-TRANSITIVE: a token scan proves
// something about the text of one named file and nothing about any file it
// calls. Each scan therefore fails hard when its file or a declaration it
// expects is missing, and asserts it actually scanned something — an empty
// read proves nothing.

import XCTest
@testable import HueHome

final class Composer2ResolverTests: XCTestCase {

    private var resolverPath: String { "HueHome/Core/Composer2Resolver.swift" }

    private enum ResolverFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
    }

    /// Every declaration this packet introduces.
    private var newDeclarations: [String] {
        ["enum Composer2Evidence",
         "struct Composer2ObservedState",
         "enum Composer2Resolver"]
    }

    private var newTypeNames: [String] {
        ["Composer2Evidence", "Composer2ObservedState", "Composer2Resolver"]
    }

    // ──────────────────────────────────────────────
    // MARK: - Fixtures
    // ──────────────────────────────────────────────

    private var producers: [Composer2Producer] { Composer2Producer.allCases }

    private var bridgeA: Composer2BridgeIdentity { .bridge("bridge-a") }
    private var bridgeB: Composer2BridgeIdentity { .bridge("bridge-b") }

    private var scopeA: Composer2GroupScope {
        Composer2GroupScope(bridge: bridgeA, group: .room("room-1"))
    }

    private var lightTarget: Composer2ConsumerTarget {
        .restLight(bridge: bridgeA, light: Composer2RESTLightIdentity("light-9"))
    }

    /// One reading per counter domain, all carrying the same numeric value so
    /// a cross-domain comparison cannot be excused as a value difference.
    private var oneReadingPerDomain: [Composer2Counter] {
        [.compositionPlayback(1), .allDayPlayback(1), .restScopeEpoch(1),
         .bridgeNativeOwnership(1), .roomOwnership(1), .bridgeAnimationReconcile(1)]
    }

    /// The five domains whose MISMATCH is proven to mean the captured work is
    /// no longer current.
    private var supersedingDomains: [Composer2Counter] {
        [.compositionPlayback(1), .allDayPlayback(1), .restScopeEpoch(1),
         .bridgeNativeOwnership(1), .roomOwnership(1)]
    }

    /// The domain whose only comparison is an inverted hydration watermark.
    private var watermarkDomain: Composer2Counter { .bridgeAnimationReconcile(1) }

    /// The two domains whose comparison treats an ABSENT current reading as a
    /// mismatch through an explicit branch.
    private var absenceProvenDomains: [Composer2Counter] {
        [.compositionPlayback(1), .bridgeNativeOwnership(1)]
    }

    private func bumped(_ counter: Composer2Counter) -> Composer2Counter {
        switch counter {
        case .compositionPlayback(let value):      return .compositionPlayback(value + 1)
        case .allDayPlayback(let value):           return .allDayPlayback(value + 1)
        case .restScopeEpoch(let value):           return .restScopeEpoch(value + 1)
        case .bridgeNativeOwnership(let value):    return .bridgeNativeOwnership(value + 1)
        case .roomOwnership(let value):            return .roomOwnership(value + 1)
        case .bridgeAnimationReconcile(let value): return .bridgeAnimationReconcile(value + 1)
        }
    }

    private func domainLabel(_ counter: Composer2Counter) -> String {
        switch counter {
        case .compositionPlayback:      return "compositionPlayback"
        case .allDayPlayback:           return "allDayPlayback"
        case .restScopeEpoch:           return "restScopeEpoch"
        case .bridgeNativeOwnership:    return "bridgeNativeOwnership"
        case .roomOwnership:            return "roomOwnership"
        case .bridgeAnimationReconcile: return "bridgeAnimationReconcile"
        }
    }

    private var entertainmentSession: Composer2SessionIdentity {
        .entertainment(bridge: bridgeA, configuration: Composer2ConfigurationIdentity("cfg-1"))
    }
    private var otherEntertainmentSession: Composer2SessionIdentity {
        .entertainment(bridge: bridgeB, configuration: Composer2ConfigurationIdentity("cfg-2"))
    }
    private var restTelemetrySession: Composer2SessionIdentity {
        .restTelemetry(scope: scopeA, producer: .composer)
    }

    private var everyHolderEvidence: [Composer2Evidence<Composer2Producer>] {
        [.absent, .unreadable, .unsupported] + producers.map { .observed($0) }
    }

    private func state(holder: Composer2Evidence<Composer2Producer> = .absent,
                       session: Composer2Evidence<Composer2SessionIdentity> = .absent,
                       counter: Composer2Evidence<Composer2Counter> = .absent)
        -> Composer2ObservedState {
        Composer2ObservedState(holder: holder, session: session, counter: counter)
    }

    private func intentRequest(producer: Composer2Producer = .composer,
                               intent: Composer2ProducerIntent = .groupState,
                               target: Composer2ConsumerTarget? = nil,
                               transport: Composer2ConsumerTransportState = .notSelected,
                               session: Composer2SessionIdentity? = nil,
                               counter: Composer2Counter? = nil) -> Composer2ConsumerRequest {
        .intent(Composer2IntentRequest(producer: producer,
                                       intent: intent,
                                       target: target ?? .group(scopeA),
                                       transport: transport,
                                       session: session,
                                       counter: counter))
    }

    private func stopRequest(producer: Composer2Producer = .composer,
                             scope: Composer2StopScope? = nil,
                             session: Composer2SessionIdentity? = nil,
                             counter: Composer2Counter? = nil) -> Composer2ConsumerRequest {
        .stop(Composer2StopRequest(producer: producer,
                                   scope: scope ?? .exact(scopeA),
                                   session: session,
                                   counter: counter))
    }

    private func resolve(_ request: Composer2ConsumerRequest,
                         _ observed: Composer2ObservedState) -> Composer2Resolution {
        Composer2Resolver.resolve(request: request, observed: observed)
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Value semantics
    // ──────────────────────────────────────────────

    /// The four evidence qualities are four values, not two spellings of one.
    /// Unknown is not absent, unsupported is not absent, and neither is free.
    func testEvidenceCasesAreMutuallyDistinctForEveryInstantiation() {
        let holders: [Composer2Evidence<Composer2Producer>] =
            [.observed(.composer), .absent, .unsupported, .unreadable]
        let sessions: [Composer2Evidence<Composer2SessionIdentity>] =
            [.observed(entertainmentSession), .absent, .unsupported, .unreadable]
        let counters: [Composer2Evidence<Composer2Counter>] =
            [.observed(.roomOwnership(1)), .absent, .unsupported, .unreadable]

        XCTAssertEqual(Set(holders).count, 4, "holder evidence must have four distinct values")
        XCTAssertEqual(Set(sessions).count, 4, "session evidence must have four distinct values")
        XCTAssertEqual(Set(counters).count, 4, "counter evidence must have four distinct values")

        for (index, left) in holders.enumerated() {
            for (other, right) in holders.enumerated() where other != index {
                XCTAssertNotEqual(left, right, "\(left) must not equal \(right)")
            }
        }
    }

    /// Equality and hashing follow the payload, and an observed fact never
    /// equals an unobserved one.
    func testEvidenceEqualityAndHashFollowTheirPayload() {
        XCTAssertEqual(Composer2Evidence<Composer2Producer>.observed(.studio),
                       Composer2Evidence<Composer2Producer>.observed(.studio))
        XCTAssertNotEqual(Composer2Evidence<Composer2Producer>.observed(.studio),
                          Composer2Evidence<Composer2Producer>.observed(.composer))
        XCTAssertEqual(Composer2Evidence<Composer2Producer>.observed(.studio).hashValue,
                       Composer2Evidence<Composer2Producer>.observed(.studio).hashValue)

        // Two readings from different counter domains carrying the same number
        // are two different facts.
        XCTAssertNotEqual(Composer2Evidence<Composer2Counter>.observed(.roomOwnership(1)),
                          Composer2Evidence<Composer2Counter>.observed(.allDayPlayback(1)))
    }

    /// Every field participates in identity. Two observations that differ in
    /// any single field are two observations.
    func testObservedStateEqualityAndHashFollowEveryField() {
        let base = state(holder: .observed(.composer),
                         session: .observed(entertainmentSession),
                         counter: .observed(.compositionPlayback(3)))
        let same = state(holder: .observed(.composer),
                         session: .observed(entertainmentSession),
                         counter: .observed(.compositionPlayback(3)))
        XCTAssertEqual(base, same)
        XCTAssertEqual(base.hashValue, same.hashValue)

        XCTAssertNotEqual(base, state(holder: .observed(.studio),
                                      session: .observed(entertainmentSession),
                                      counter: .observed(.compositionPlayback(3))))
        XCTAssertNotEqual(base, state(holder: .observed(.composer),
                                      session: .observed(otherEntertainmentSession),
                                      counter: .observed(.compositionPlayback(3))))
        XCTAssertNotEqual(base, state(holder: .observed(.composer),
                                      session: .observed(entertainmentSession),
                                      counter: .observed(.compositionPlayback(4))))
        XCTAssertNotEqual(base, state(holder: .observed(.composer),
                                      session: .absent,
                                      counter: .observed(.compositionPlayback(3))))
        XCTAssertNotEqual(base, state(holder: .observed(.composer),
                                      session: .unreadable,
                                      counter: .observed(.compositionPlayback(3))))
    }

    /// The initializer preserves every field AND supplies no defaults: an
    /// observation must state its own evidence quality, because a default is
    /// exactly the silent assumption this type exists to remove.
    func testObservedStateInitializerHasNoDefaultsAndPreservesEveryField() throws {
        let observed = Composer2ObservedState(holder: .observed(.siri),
                                              session: .unsupported,
                                              counter: .unreadable)
        XCTAssertEqual(observed.holder, .observed(.siri))
        XCTAssertEqual(observed.session, .unsupported)
        XCTAssertEqual(observed.counter, .unreadable)

        let src = try resolverSource()
        let signature = try requireInitSignature(in: src)
        requireAbsent("=", in: signature,
                      "the observed-state initializer must supply no default arguments")
        for label in ["holder:", "session:", "counter:"] {
            XCTAssertTrue(signature.contains(label),
                          "the initializer must take \(label), or this guard is stale")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Determinism
    // ──────────────────────────────────────────────

    /// Identical inputs yield identical outputs, every time. No clock, no
    /// randomness, no accumulated state between calls.
    func testResolveIsDeterministicForIdenticalInputs() {
        var pinned = 0
        for holder in everyHolderEvidence {
            for producer in producers {
                for counter in oneReadingPerDomain {
                    let observed = state(holder: holder,
                                         session: .observed(entertainmentSession),
                                         counter: .observed(counter))
                    let request = intentRequest(producer: producer,
                                                session: entertainmentSession,
                                                counter: counter)
                    let first = resolve(request, observed)
                    for _ in 0..<4 {
                        XCTAssertEqual(resolve(request, observed), first,
                                       "resolve must be deterministic for \(holder)/\(producer)")
                    }
                    let stop = stopRequest(producer: producer,
                                           session: entertainmentSession,
                                           counter: counter)
                    let firstStop = resolve(stop, observed)
                    for _ in 0..<4 {
                        XCTAssertEqual(resolve(stop, observed), firstStop)
                    }
                    pinned += 2
                }
            }
        }
        XCTAssertGreaterThan(pinned, 0, "an empty sweep proves nothing")
    }

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
        XCTAssertFalse(scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty read proves nothing")

        let forbidden = ["Task" + "." + "sleep",
                         "XCT" + "Waiter",
                         "wait" + "(for:",
                         "expect" + "ation("]
        for token in forbidden {
            XCTAssertFalse(scanned.contains(token),
                           "this file must contain no timing wait — found: \(token)")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Origin identity and precedence
    // ──────────────────────────────────────────────

    /// A resolution names the OBSERVED HOLDER, never the request's origin.
    /// The origin is where the work came from; it is never promoted into a
    /// claim about who holds the resource.
    func testResolutionNamesTheObservedHolderNeverTheRequestOrigin() {
        var checked = 0
        for holder in producers where holder != .foreignController {
            for origin in producers where origin != holder {
                let resolution = resolve(intentRequest(producer: origin),
                                         state(holder: .observed(holder)))
                guard case .requiresRelease(let named, let because) = resolution else {
                    XCTFail("expected requiresRelease for holder \(holder), got \(resolution)")
                    continue
                }
                XCTAssertEqual(named, holder,
                               "the released producer must be the holder, not the origin \(origin)")
                XCTAssertNotEqual(named, origin,
                                  "the origin must never be named as the holder")
                XCTAssertEqual(because, .heldByProducer(holder))
                checked += 1
            }
        }
        XCTAssertEqual(checked, 8 * 8, "every unequal in-app origin/holder pair must be covered")
    }

    /// An intent's resolution is a function of the observed holder ALONE.
    /// Nine origins against nine holders give one answer per holder, so no
    /// precedence table can be hiding here.
    func testIntentResolutionIsIndependentOfTheOriginProducer() {
        var pinned = 0
        for holderEvidence in everyHolderEvidence {
            let observed = state(holder: holderEvidence)
            let baseline = resolve(intentRequest(producer: .composer), observed)
            for origin in producers {
                XCTAssertEqual(resolve(intentRequest(producer: origin), observed), baseline,
                               "intent resolution must not depend on the origin (\(origin))")
                pinned += 1
            }
        }
        XCTAssertEqual(pinned, 12 * 9)
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Output shape
    // ──────────────────────────────────────────────

    /// Every reachable answer is one of the six accepted resolution shapes,
    /// and the seam introduces no seventh.
    func testTheReachableResolutionSetIsExactlyTheSixAcceptedCases() {
        var seen: Set<String> = []
        func note(_ resolution: Composer2Resolution) {
            switch resolution {
            case .proceed:              seen.insert("proceed")
            case .nothingToDo:          seen.insert("nothingToDo")
            case .requiresRelease:      seen.insert("requiresRelease")
            case .requiresUserDecision: seen.insert("requiresUserDecision")
            case .refuse:               seen.insert("refuse")
            case .undetermined:         seen.insert("undetermined")
            }
        }

        for holder in everyHolderEvidence {
            note(resolve(intentRequest(), state(holder: holder)))
            note(resolve(stopRequest(), state(holder: holder)))
            note(resolve(stopRequest(scope: .everything), state(holder: holder)))
        }
        note(resolve(intentRequest(counter: .compositionPlayback(1)),
                     state(counter: .observed(.compositionPlayback(2)))))

        XCTAssertEqual(seen, ["proceed", "nothingToDo", "requiresRelease",
                              "requiresUserDecision", "refuse", "undetermined"],
                       "the seam must reach exactly the six accepted resolution shapes")
    }

    /// `proceed` carries no transport, and the seam never returns a
    /// transport-bearing contention. Selecting a transport is policy this
    /// packet does not hold.
    func testNoResolutionCarriesATransport() {
        var pinned = 0
        for holder in everyHolderEvidence {
            for scope in [Composer2StopScope.exact(scopeA),
                          .anyBridgeHosting(.room("room-1")),
                          .everything] {
                for resolution in [resolve(intentRequest(), state(holder: holder)),
                                   resolve(stopRequest(scope: scope), state(holder: holder))] {
                    switch resolution {
                    case .refuse(let because), .undetermined(let because),
                         .requiresUserDecision(let because):
                        XCTAssertNotEqual(because, .transportUnavailable(.entertainment))
                        XCTAssertNotEqual(because, .transportUnavailable(.rest))
                        XCTAssertNotEqual(because, .transportUnavailable(.bridgeStored))
                        XCTAssertNotEqual(because, .transportUnavailable(.oneShot))
                    case .requiresRelease(_, let because):
                        for transport in Composer2Transport.allCases {
                            XCTAssertNotEqual(because, .transportUnavailable(transport))
                        }
                    case .proceed:
                        XCTAssertEqual(resolution, Composer2Resolution.proceed,
                                       "proceed must carry nothing at all")
                    case .nothingToDo:
                        XCTAssertEqual(resolution, Composer2Resolution.nothingToDo)
                    }
                    pinned += 1
                }
            }
        }
        XCTAssertGreaterThan(pinned, 0, "an empty sweep proves nothing")
    }

    /// Whether a transport is already bound for this request changes nothing.
    /// `notSelected` is not an invitation to choose one.
    func testResolutionIsIndependentOfTransportState() {
        var pinned = 0
        for holder in everyHolderEvidence {
            let observed = state(holder: holder)
            let baseline = resolve(intentRequest(transport: .notSelected), observed)
            for transport in Composer2Transport.allCases {
                XCTAssertEqual(resolve(intentRequest(transport: .selected(transport)), observed),
                               baseline,
                               "binding \(transport) must not change the resolution")
                pinned += 1
            }
        }
        XCTAssertEqual(pinned, 12 * 4)
    }

    /// The semantic operation does not change contention. Contention is about
    /// the resource, not the verb.
    func testResolutionIsIndependentOfIntentKind() {
        var pinned = 0
        for holder in everyHolderEvidence {
            let observed = state(holder: holder)
            let baseline = resolve(intentRequest(intent: .groupState), observed)
            for intent in Composer2ProducerIntent.allCases {
                XCTAssertEqual(resolve(intentRequest(intent: intent), observed), baseline)
                pinned += 1
            }
        }
        XCTAssertEqual(pinned, 12 * 6)
    }

    // ──────────────────────────────────────────────
    // MARK: - E. Light targets
    // ──────────────────────────────────────────────

    /// A REST light request is never silently mapped to the group around it.
    /// The seam does not read the target at all, so a light cannot inherit a
    /// room's contention and a room cannot inherit a light's.
    func testRESTLightAndGroupTargetsResolveIdentically() {
        var pinned = 0
        for holder in everyHolderEvidence {
            let observed = state(holder: holder)
            let byGroup = resolve(intentRequest(target: .group(scopeA)), observed)
            let byLight = resolve(intentRequest(target: lightTarget), observed)
            let byBridge = resolve(intentRequest(target: .bridge(bridgeA)), observed)
            let bySystem = resolve(intentRequest(target: .wholeSystem), observed)
            XCTAssertEqual(byLight, byGroup, "a light must not inherit a group's answer path")
            XCTAssertEqual(byBridge, byGroup)
            XCTAssertEqual(bySystem, byGroup)
            pinned += 3
        }
        XCTAssertEqual(pinned, 12 * 3)

        // And an unrecorded resource is answered truthfully rather than freely.
        XCTAssertEqual(resolve(intentRequest(target: lightTarget), state(holder: .unsupported)),
                       .undetermined(.evidenceUnreadable),
                       "a resource with no ownership record must not resolve as free")
    }

    // ──────────────────────────────────────────────
    // MARK: - F. Unknown, absent, unsupported, free
    // ──────────────────────────────────────────────

    /// The four evidence qualities give four different answers for an intent.
    /// If any two collapsed, one of them would be a lie.
    func testTheFourHolderEvidenceCasesYieldFourDistinctIntentResolutions() {
        XCTAssertEqual(resolve(intentRequest(), state(holder: .absent)), .proceed)
        XCTAssertEqual(resolve(intentRequest(), state(holder: .unreadable)),
                       .refuse(because: .evidenceUnreadable))
        XCTAssertEqual(resolve(intentRequest(), state(holder: .unsupported)),
                       .undetermined(.evidenceUnreadable))
        XCTAssertEqual(resolve(intentRequest(), state(holder: .observed(.studio))),
                       .requiresRelease(of: .studio, because: .heldByProducer(.studio)))

        let answers: Set<Composer2Resolution> = [
            resolve(intentRequest(), state(holder: .absent)),
            resolve(intentRequest(), state(holder: .unreadable)),
            resolve(intentRequest(), state(holder: .unsupported)),
            resolve(intentRequest(), state(holder: .observed(.studio)))
        ]
        XCTAssertEqual(answers.count, 4,
                       "unknown, absent, unsupported and held must not collapse")
    }

    /// The same four qualities give four different answers for an exact stop.
    func testTheFourHolderEvidenceCasesYieldFourDistinctExactStopResolutions() {
        XCTAssertEqual(resolve(stopRequest(), state(holder: .absent)), .nothingToDo)
        XCTAssertEqual(resolve(stopRequest(), state(holder: .unreadable)),
                       .refuse(because: .evidenceUnreadable))
        XCTAssertEqual(resolve(stopRequest(), state(holder: .unsupported)),
                       .undetermined(.evidenceUnreadable))
        XCTAssertEqual(resolve(stopRequest(producer: .composer),
                               state(holder: .observed(.composer))), .proceed)

        let answers: Set<Composer2Resolution> = [
            resolve(stopRequest(), state(holder: .absent)),
            resolve(stopRequest(), state(holder: .unreadable)),
            resolve(stopRequest(), state(holder: .unsupported)),
            resolve(stopRequest(producer: .studio), state(holder: .observed(.composer)))
        ]
        XCTAssertEqual(answers.count, 4)
    }

    /// Unreadable and unsupported evidence never authorize action and never
    /// claim there is nothing to do. Unknown is not verified.
    func testUnreadableAndUnsupportedNeverYieldProceedOrNothingToDo() {
        var pinned = 0
        for quality in [Composer2Evidence<Composer2Producer>.unreadable, .unsupported] {
            for producer in producers {
                for request in [intentRequest(producer: producer),
                                stopRequest(producer: producer),
                                stopRequest(producer: producer, scope: .everything),
                                stopRequest(producer: producer,
                                            scope: .anyBridgeHosting(.room("room-1")))] {
                    let resolution = resolve(request, state(holder: quality))
                    XCTAssertNotEqual(resolution, .proceed,
                                      "\(quality) must never authorize action")
                    XCTAssertNotEqual(resolution, .nothingToDo,
                                      "\(quality) must never claim emptiness")
                    pinned += 1
                }
            }
        }
        XCTAssertEqual(pinned, 2 * 9 * 4)
    }

    /// A bridge that could not be read stays fail-closed. It never resolves as
    /// free, and it never becomes a consent question about a session nobody
    /// managed to observe.
    func testUnreadableEvidenceStaysFailClosedAndAsksNothing() {
        for request in [intentRequest(target: .bridge(bridgeA)),
                        intentRequest(target: .group(scopeA)),
                        stopRequest()] {
            let resolution = resolve(request, state(holder: .unreadable))
            XCTAssertEqual(resolution, .refuse(because: .evidenceUnreadable))
            XCTAssertNotEqual(resolution,
                              .requiresUserDecision(about: .heldByProducer(.foreignController)),
                              "an unread bridge must not be presented as a takeover question")
        }
    }

    /// A controller outside this app is the one holder the app cannot ask to
    /// release, so it is the one holder that becomes a decision for the
    /// person using the app. No other producer does.
    func testForeignControllerHolderIsTheOnlyUserDecision() {
        XCTAssertEqual(resolve(intentRequest(), state(holder: .observed(.foreignController))),
                       .requiresUserDecision(about: .heldByProducer(.foreignController)))
        for holder in producers where holder != .foreignController {
            let resolution = resolve(intentRequest(), state(holder: .observed(holder)))
            XCTAssertEqual(resolution,
                           .requiresRelease(of: holder, because: .heldByProducer(holder)),
                           "\(holder) must resolve as a release, not a question")
        }
        // Even when the foreign controller is the origin naming itself.
        XCTAssertEqual(resolve(intentRequest(producer: .foreignController),
                               state(holder: .observed(.foreignController))),
                       .requiresUserDecision(about: .heldByProducer(.foreignController)))
    }

    // ──────────────────────────────────────────────
    // MARK: - G. Counters, per domain
    // ──────────────────────────────────────────────

    /// A same-domain mismatch supersedes ONLY in the five domains that prove
    /// it. The reconciliation watermark is not one of them: its comparison
    /// runs the other way round, so reading a mismatch there as staleness
    /// would state its meaning backwards.
    func testCounterMismatchSupersedesOnlyInProvenDomains() {
        for counter in supersedingDomains {
            let resolution = resolve(intentRequest(counter: counter),
                                     state(counter: .observed(bumped(counter))))
            XCTAssertEqual(resolution, .refuse(because: .superseded),
                           "\(domainLabel(counter)) must supersede on mismatch")
        }
        let watermark = watermarkDomain
        XCTAssertEqual(resolve(intentRequest(counter: watermark),
                               state(counter: .observed(bumped(watermark)))),
                       .proceed,
                       "the reconciliation watermark must draw no staleness conclusion")
        XCTAssertEqual(supersedingDomains.count + 1, oneReadingPerDomain.count,
                       "every counter domain must be classified, or this guard is stale")
    }

    /// A same-domain match never supersedes, in any domain.
    func testCounterMatchNeverSupersedesInAnyDomain() {
        for counter in oneReadingPerDomain {
            XCTAssertEqual(resolve(intentRequest(counter: counter),
                                   state(counter: .observed(counter))),
                           .proceed,
                           "\(domainLabel(counter)) must not supersede on a match")
        }
    }

    /// What an ABSENT current reading means is proven in two domains and
    /// unproven in the rest. Where it is unproven, nothing is claimed.
    func testAbsentCounterEvidenceIsStaleOnlyWhereProven() {
        for counter in absenceProvenDomains {
            XCTAssertEqual(resolve(intentRequest(counter: counter), state(counter: .absent)),
                           .refuse(because: .superseded),
                           "\(domainLabel(counter)) treats a missing entry as a mismatch")
        }
        let unproven = supersedingDomains.filter { candidate in
            !absenceProvenDomains.contains(candidate)
        }
        XCTAssertEqual(unproven.count, 3, "three superseding domains leave absence unproven")
        for counter in unproven {
            XCTAssertEqual(resolve(intentRequest(counter: counter), state(counter: .absent)),
                           .undetermined(.evidenceUnreadable),
                           "\(domainLabel(counter)) proves nothing from absence")
        }
        XCTAssertEqual(resolve(intentRequest(counter: watermarkDomain), state(counter: .absent)),
                       .proceed)
    }

    /// Unreadable and unsupported counter evidence prove nothing, and the
    /// watermark domain still draws no conclusion.
    func testUnreadableAndUnsupportedCounterEvidenceProveNothing() {
        for quality in [Composer2Evidence<Composer2Counter>.unreadable, .unsupported] {
            for counter in supersedingDomains {
                XCTAssertEqual(resolve(intentRequest(counter: counter), state(counter: quality)),
                               .undetermined(.evidenceUnreadable),
                               "\(domainLabel(counter)) under \(quality) must prove nothing")
            }
            XCTAssertEqual(resolve(intentRequest(counter: watermarkDomain),
                                   state(counter: quality)),
                           .proceed)
        }
    }

    /// Unrelated counter domains are NEVER compared. All thirty ordered
    /// cross-domain pairs resolve exactly as if no counter had been carried at
    /// all — including the unsigned domain against every signed one, which a
    /// numeric comparison would have had to widen to reach.
    func testUnrelatedCounterDomainsAreNeverCompared() {
        let neutral = resolve(intentRequest(), state())
        XCTAssertEqual(neutral, .proceed, "the control row must be a plain proceed")

        var pairs = 0
        for requested in oneReadingPerDomain {
            for observed in oneReadingPerDomain
            where domainLabel(observed) != domainLabel(requested) {
                // Deliberately differing values: a numeric comparison across
                // domains would report a mismatch and refuse.
                let resolution = resolve(intentRequest(counter: requested),
                                         state(counter: .observed(bumped(observed))))
                XCTAssertEqual(resolution, neutral,
                               "\(domainLabel(requested)) vs \(domainLabel(observed)) "
                               + "must prove nothing")
                XCTAssertNotEqual(resolution, .refuse(because: .superseded),
                                  "unrelated counter domains must never be compared")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 30, "all thirty ordered cross-domain pairs must be covered")
    }

    /// The reconciliation watermark can never produce a superseded verdict, in
    /// any combination of the other observed fields or either request shape.
    func testWatermarkCounterDomainNeverYieldsSuperseded() {
        var pinned = 0
        let evidences: [Composer2Evidence<Composer2Counter>] =
            [.absent, .unsupported, .unreadable]
            + oneReadingPerDomain.map { .observed($0) }
            + oneReadingPerDomain.map { .observed(bumped($0)) }
        for holder in everyHolderEvidence {
            for evidence in evidences {
                for request in [intentRequest(counter: watermarkDomain),
                                stopRequest(counter: watermarkDomain)] {
                    let resolution = resolve(request,
                                             state(holder: holder, counter: evidence))
                    XCTAssertNotEqual(resolution, .refuse(because: .superseded),
                                      "the watermark domain must never supersede")
                    pinned += 1
                }
            }
        }
        XCTAssertEqual(pinned, 12 * 15 * 2)
    }

    // ──────────────────────────────────────────────
    // MARK: - H. Sessions
    // ──────────────────────────────────────────────

    /// Two identities in the same namespace that are not the same identity
    /// mean the captured work has been replaced.
    func testSameNamespaceSessionMismatchIsSuperseded() {
        XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                               state(session: .observed(otherEntertainmentSession))),
                       .refuse(because: .superseded))
        XCTAssertEqual(resolve(stopRequest(session: entertainmentSession),
                               state(session: .observed(otherEntertainmentSession))),
                       .refuse(because: .superseded))
    }

    /// The same identity is not superseded.
    func testSameNamespaceSessionMatchIsNotSuperseded() {
        XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                               state(session: .observed(entertainmentSession))),
                       .proceed)
        XCTAssertEqual(resolve(intentRequest(session: restTelemetrySession),
                               state(session: .observed(restTelemetrySession))),
                       .proceed)
    }

    /// The two session namespaces do not share a key shape, so identities
    /// drawn from different namespaces are never compared for currency.
    func testCrossNamespaceSessionsAreNeverCompared() {
        let neutral = resolve(intentRequest(), state())
        XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                               state(session: .observed(restTelemetrySession))),
                       neutral,
                       "an entertainment identity proves nothing about a telemetry one")
        XCTAssertEqual(resolve(intentRequest(session: restTelemetrySession),
                               state(session: .observed(entertainmentSession))),
                       neutral)
    }

    /// An absent or unsupported session proves nothing: a session that ended
    /// before a confirmation landed leaves nothing to stop, and the holder
    /// field already states whether anything is there.
    func testAbsentAndUnsupportedSessionEvidenceProveNothing() {
        for quality in [Composer2Evidence<Composer2SessionIdentity>.absent, .unsupported] {
            XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                                   state(holder: .absent, session: quality)),
                           .proceed)
            XCTAssertEqual(resolve(stopRequest(session: entertainmentSession),
                                   state(holder: .absent, session: quality)),
                           .nothingToDo,
                           "nothing to remove is a success, not a refusal")
            XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                                   state(holder: .observed(.studio), session: quality)),
                           .requiresRelease(of: .studio, because: .heldByProducer(.studio)))
        }
    }

    /// A session that could not be read proves nothing either way.
    func testUnreadableSessionEvidenceIsUndetermined() {
        XCTAssertEqual(resolve(intentRequest(session: entertainmentSession),
                               state(session: .unreadable)),
                       .undetermined(.evidenceUnreadable))
        // A request carrying no session is unaffected by unreadable session
        // evidence: there is nothing to check.
        XCTAssertEqual(resolve(intentRequest(), state(session: .unreadable)), .proceed)
    }

    // ──────────────────────────────────────────────
    // MARK: - I. Stops
    // ──────────────────────────────────────────────

    /// Nothing to remove is a success.
    func testExactStopOnAbsentHolderIsNothingToDo() {
        for producer in producers {
            XCTAssertEqual(resolve(stopRequest(producer: producer), state(holder: .absent)),
                           .nothingToDo)
        }
    }

    /// A producer whose own work is what is observed may proceed.
    func testExactStopByTheObservedHolderProceeds() {
        for producer in producers {
            XCTAssertEqual(resolve(stopRequest(producer: producer),
                                   state(holder: .observed(producer))),
                           .proceed,
                           "\(producer) stopping its own observed work must proceed")
        }
    }

    /// Whether one runtime may end another runtime's work has no settled
    /// answer, so all seventy-two unequal pairs are undetermined — never
    /// executed, never refused outright, and never silently allowed.
    func testCrossProducerExactStopIsUndetermined() {
        var pairs = 0
        for origin in producers {
            for holder in producers where holder != origin {
                XCTAssertEqual(resolve(stopRequest(producer: origin),
                                       state(holder: .observed(holder))),
                               .undetermined(.heldByProducer(holder)),
                               "\(origin) stopping \(holder) has no settled answer")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 72, "all seventy-two unequal ordered pairs must be covered")
    }

    /// The cross-producer verdict is symmetric under swap: exchanging which
    /// producer originated the stop and which is holding keeps the answer's
    /// shape. A precedence table could not be symmetric.
    func testCrossProducerStopVerdictIsSymmetricUnderSwap() {
        for origin in producers {
            for holder in producers where holder != origin {
                let forward = resolve(stopRequest(producer: origin),
                                      state(holder: .observed(holder)))
                let reversed = resolve(stopRequest(producer: holder),
                                       state(holder: .observed(origin)))
                guard case .undetermined(let forwardBecause) = forward,
                      case .undetermined(let reverseBecause) = reversed else {
                    XCTFail("both directions must be undetermined")
                    continue
                }
                XCTAssertEqual(forwardBecause, .heldByProducer(holder))
                XCTAssertEqual(reverseBecause, .heldByProducer(origin))
            }
        }
    }

    /// A stop naming no bridge, and a stop naming no resource, are both
    /// undetermined for every observation. The seam does not infer which
    /// bridge hosts a group, and a single-resource observation cannot speak
    /// for a sweep.
    func testAnyBridgeHostingAndEverythingAreAlwaysUndetermined() {
        var pinned = 0
        for scope in [Composer2StopScope.anyBridgeHosting(.room("room-1")),
                      .anyBridgeHosting(.zone("zone-1")),
                      .everything] {
            for holder in everyHolderEvidence {
                for producer in producers {
                    let resolution = resolve(stopRequest(producer: producer, scope: scope),
                                             state(holder: holder))
                    XCTAssertEqual(resolution, .undetermined(.evidenceUnreadable),
                                   "\(scope) must not be resolved from a target observation")
                    pinned += 1
                }
            }
        }
        XCTAssertEqual(pinned, 3 * 12 * 9)
    }

    /// A stop is not an intent wearing a different hat. For the same producer
    /// and the same observation the two answers differ wherever the table says
    /// they should.
    func testStopIsNotResolvedLikeAnIntent() {
        XCTAssertNotEqual(resolve(stopRequest(producer: .composer),
                                  state(holder: .observed(.composer))),
                          resolve(intentRequest(producer: .composer),
                                  state(holder: .observed(.composer))),
                          "a holder stopping its own work is not the same as writing to it")
        XCTAssertNotEqual(resolve(stopRequest(), state(holder: .absent)),
                          resolve(intentRequest(), state(holder: .absent)),
                          "an empty resource means nothing to stop, but is free to write")
        XCTAssertNotEqual(resolve(stopRequest(producer: .studio),
                                  state(holder: .observed(.composer))),
                          resolve(intentRequest(producer: .studio),
                                  state(holder: .observed(.composer))))
    }

    // ──────────────────────────────────────────────
    // MARK: - J. Totality
    // ──────────────────────────────────────────────

    /// The full semantic table: every holder evidence case against every
    /// request shape and every stop scope. Each row is pinned to an exact
    /// resolution, so a missing branch shows up as a wrong answer rather than
    /// as an absent test.
    func testTheFullSemanticTableIsPinned() {
        var rows = 0
        for holder in everyHolderEvidence {
            // Intents.
            let intentExpected: Composer2Resolution
            switch holder {
            case .absent:                        intentExpected = .proceed
            case .unreadable:                    intentExpected = .refuse(because: .evidenceUnreadable)
            case .unsupported:                   intentExpected = .undetermined(.evidenceUnreadable)
            case .observed(.foreignController):
                intentExpected = .requiresUserDecision(about: .heldByProducer(.foreignController))
            case .observed(let producer):
                intentExpected = .requiresRelease(of: producer,
                                                  because: .heldByProducer(producer))
            }
            XCTAssertEqual(resolve(intentRequest(producer: .composer), state(holder: holder)),
                           intentExpected, "intent row for \(holder)")
            rows += 1

            // Exact stops, originated by .composer.
            let stopExpected: Composer2Resolution
            switch holder {
            case .absent:              stopExpected = .nothingToDo
            case .unreadable:          stopExpected = .refuse(because: .evidenceUnreadable)
            case .unsupported:         stopExpected = .undetermined(.evidenceUnreadable)
            case .observed(.composer): stopExpected = .proceed
            case .observed(let producer):
                stopExpected = .undetermined(.heldByProducer(producer))
            }
            XCTAssertEqual(resolve(stopRequest(producer: .composer), state(holder: holder)),
                           stopExpected, "exact-stop row for \(holder)")
            rows += 1

            // The two scopes the seam refuses to resolve.
            for scope in [Composer2StopScope.anyBridgeHosting(.room("room-1")), .everything] {
                XCTAssertEqual(resolve(stopRequest(producer: .composer, scope: scope),
                                       state(holder: holder)),
                               .undetermined(.evidenceUnreadable),
                               "\(scope) row for \(holder)")
                rows += 1
            }
        }
        XCTAssertEqual(rows, 12 * 4, "every holder case must be pinned for every request shape")
    }

    // ──────────────────────────────────────────────
    // MARK: - K. Source shape
    // ──────────────────────────────────────────────

    /// The resolver file is a pure value computation. This is a claim about
    /// the TEXT of that one file and is deliberately non-transitive.
    func testResolverSourceIsSideEffectFree() throws {
        let src = try resolverSource()
        XCTAssertFalse(src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty read proves nothing")
        for declaration in newDeclarations {
            XCTAssertTrue(src.contains(declaration),
                          "\(declaration) must exist in the resolver file, "
                          + "or this guard is stale")
        }

        let banned = ["import ", "Task", "async", "await", "actor ", "class ",
                      "var ", "shared", "UserDefaults", "Keychain",
                      "NotificationCenter", "DispatchQueue", "URLSession",
                      "SwiftUI", "UIKit", "os_log", "print(", "@escaping",
                      "@MainActor", "Any", "[String:", "HueAPIClient",
                      "HueEntertainmentClient", "RestSender", "UnifiedOrchestrator",
                      "StudioViewModel", "FlagStore", "Composer2Flag",
                      "fatalError", "preconditionFailure", "try!", "as!",
                      "Date", "UUID", "default:"]
        for token in banned {
            requireAbsent(token, in: src, "the resolver source")
        }
    }

    /// The resolver names no transport type and no target type. It cannot
    /// select a transport it cannot spell, and it cannot map a light to a room
    /// it never reads.
    func testResolverSourceNamesNoTransportOrTargetType() throws {
        let src = try resolverSource()
        for token in ["Composer2Transport", "Composer2ConsumerTransportState",
                      "notSelected", "selected(",
                      "Composer2ConsumerTarget", "Composer2GroupScope",
                      "Composer2GroupIdentity", "Composer2RESTLightIdentity",
                      "restLight", "wholeSystem", "target"] {
            requireAbsent(token, in: src, "the resolver source")
        }
    }

    /// The resolver receives no capability catalog and duplicates none. What
    /// an origin CAN express is a different question from what is true of this
    /// resource right now.
    func testResolverSourceEmbedsNoRegistration() throws {
        let src = try resolverSource()
        for token in ["Composer2ProducerRegistration", "Composer2RegistrationProvenance",
                      "Composer2RegistrationScopeKind", "Composer2RegistrationStopKind",
                      "Composer2RegistrationSessionNamespace", "Composer2ProducerIntent",
                      "provenance", "catalog", "Catalog", "reachableTransports",
                      "scopeKinds", "stopKinds"] {
            requireAbsent(token, in: src, "the resolver source")
        }
    }

    /// No second resolution vocabulary is introduced, and no ordering exists
    /// anywhere in the file.
    func testResolverIntroducesNoSecondResolutionEnumAndNoOrdering() throws {
        let src = try resolverSource()
        let declared = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("enum ") || $0.hasPrefix("struct ") || $0.hasPrefix("class ") }
            .map { line -> String in
                let dropped = line.hasPrefix("enum ") ? String(line.dropFirst(5))
                            : line.hasPrefix("struct ") ? String(line.dropFirst(7))
                            : String(line.dropFirst(6))
                return String(dropped.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            }
        XCTAssertEqual(Set(declared), Set(newTypeNames),
                       "the file must declare exactly the three approved top-level types, "
                       + "found: \(declared)")

        for token in ["Comparable", "static func <", "priority", "rank", "wins",
                      "beats", "outrank", "precede", "winner", "loser",
                      "canOverride", "mayOverride"] {
            requireAbsent(token, in: src, "the resolver source")
        }
    }

    /// No runtime production file consumes the resolver. The only production
    /// source naming any of its three types is the declaration file itself —
    /// this packet ships a seam, not an integration.
    func testNoProductionCodeConsumesTheResolver() throws {
        let definitionFile = "Composer2Resolver.swift"

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
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            scannedCount += 1
            guard url.lastPathComponent != definitionFile else {
                definitionSource = source
                continue
            }
            for type in newTypeNames where source.contains(type) {
                offenders.append("\(url.lastPathComponent): \(type)")
            }
        }

        XCTAssertGreaterThan(scannedCount, 0,
                             "an empty scan proves nothing — the walk must cover sources")
        let definition = try XCTUnwrap(definitionSource,
                                       "the scan must have visited the resolver file")
        for type in newTypeNames {
            XCTAssertTrue(definition.contains(type),
                          "\(type) must exist in the resolver file, or this guard is stale")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "no runtime consumer is authorized in Phase 1D: \(offenders)")
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Source with comments and string literals removed, so a token scan
    /// cannot be satisfied or tripped by prose.
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

    private func resolverSource(file: StaticString = #filePath,
                                line: UInt = #line) throws -> String {
        let url = repoRoot().appendingPathComponent(resolverPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(resolverPath)", file: file, line: line)
            throw ResolverFailure.missingFile(resolverPath)
        }
        return normalized(raw)
    }

    /// The observed-state initializer's parameter list, up to its opening brace.
    private func requireInitSignature(in source: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws -> String {
        guard let start = source.range(of: "init(holder:") else {
            XCTFail("\(resolverPath): initializer not found", file: file, line: line)
            throw ResolverFailure.missingSymbol("init(holder:")
        }
        let tail = source[start.lowerBound...]
        guard let brace = tail.range(of: "{") else {
            XCTFail("\(resolverPath): initializer body not found", file: file, line: line)
            throw ResolverFailure.emptyBody("init(holder:")
        }
        return String(tail[..<brace.lowerBound])
    }

    private func requireAbsent(_ needle: String,
                               in body: String,
                               _ what: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertFalse(body.contains(needle),
                       "\(what): did not expect \(needle)", file: file, line: line)
    }
}
