// Composer2ConsumerContractsTests.swift
// ChromaGlow — Composer 2 Phase 1C4.
//
// CONSUMER CONTRACTS ONLY. Every assertion is about the value semantics and the
// semantic boundaries of the typed consumer request. Nothing here starts a
// runtime, constructs an orchestrator, reads a seam, or consumes a flag — the
// behavioral claims stay in the 1B1/1B2/1C1 characterization suites and are
// deliberately not restated.
//
// What this file proves:
//   • an intent request and a stop request are values, and every field carries
//     identity;
//   • every request reuses the accepted producer vocabulary rather than
//     inventing a second identity for the nine origins;
//   • non-stop work reuses the accepted producer INTENT vocabulary — no second
//     operation enum was introduced;
//   • the four target shapes stay mutually distinct, group targets preserve
//     bridge identity and room-versus-zone, and the bridgeless CASE never
//     collides with a real bridge spelled "legacy" or "";
//   • an individual-light target keeps its Hue REST resource namespace, names
//     no group, and is not an Entertainment channel;
//   • stops use the accepted stop scope;
//   • transport state distinguishes "bound for this request" from "not chosen
//     yet" with no automatic, preference, or fallback semantics;
//   • session and counter are ACTUAL instance facts, never synthesized from a
//     registration namespace or a producer's usual habits;
//   • a request carries no command payload, no precedence or resolution field,
//     and no embedded registration or capability set;
//   • the production file is UI/network/storage independent;
//   • no runtime production file consumes the consumer contracts.
//
// Source-shape claims here are NON-TRANSITIVE, following the 1B2/1C1/1C2/1C3
// discipline: each speaks only about the brace-matched declaration it
// extracted, never about callees. Every lookup fails hard — a missing file or a
// missing declaration is a failure, never a silent skip and never a fallback to
// a whole-file substring count. Comments AND string-literal contents are
// stripped before any token assertion, so documentation prose can neither
// satisfy nor break a guard.
//
// The two accepted-file integrity tests are deliberately NON-TRANSITIVE too:
// they prove the accepted declarations are still present and that no consumer
// type was smuggled into either file. Byte-identity with the accepted ancestry
// is proven by git in this packet's validation, not asserted here — a pinned
// digest would break on every future packet without proving anything more.
//
// SCOPE OF PROOF: these are source-shape and value-semantics tests running on a
// simulator. They validate no physical bridge behavior whatsoever.
//
// Determinism: no timing waits of any kind. Enforced by the last test here.

import XCTest
@testable import HueHome

@MainActor
final class Composer2ConsumerContractsTests: XCTestCase {

    private var contractsPath: String { "HueHome/Core/Composer2ConsumerContracts.swift" }
    private var domainPath: String { "HueHome/Core/Composer2Domain.swift" }
    private var registrationPath: String { "HueHome/Core/Composer2Registration.swift" }

    private enum ContractFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
    }

    /// Every declaration this packet introduces. Used by the guards so a newly
    /// added type cannot quietly escape them.
    private var newDeclarations: [String] {
        ["struct Composer2RESTLightIdentity",
         "enum Composer2ConsumerTarget",
         "enum Composer2ConsumerTransportState",
         "struct Composer2IntentRequest",
         "struct Composer2StopRequest",
         "enum Composer2ConsumerRequest"]
    }

    private var newTypeNames: [String] {
        ["Composer2RESTLightIdentity", "Composer2ConsumerTarget",
         "Composer2ConsumerTransportState", "Composer2IntentRequest",
         "Composer2StopRequest", "Composer2ConsumerRequest"]
    }

    // ──────────────────────────────────────────────
    // MARK: - Sample values
    // ──────────────────────────────────────────────

    private var livingRoomOnBridgeA: Composer2GroupScope {
        Composer2GroupScope(bridge: .bridge("A"), group: .room("living"))
    }

    private func intentRequest(
        producer: Composer2Producer = .composer,
        intent: Composer2ProducerIntent = .groupState,
        target: Composer2ConsumerTarget? = nil,
        transport: Composer2ConsumerTransportState = .notSelected,
        session: Composer2SessionIdentity? = nil,
        counter: Composer2Counter? = nil
    ) -> Composer2IntentRequest {
        Composer2IntentRequest(
            producer: producer,
            intent: intent,
            target: target ?? .group(livingRoomOnBridgeA),
            transport: transport,
            session: session,
            counter: counter)
    }

    private func stopRequest(
        producer: Composer2Producer = .manual,
        scope: Composer2StopScope? = nil,
        session: Composer2SessionIdentity? = nil,
        counter: Composer2Counter? = nil
    ) -> Composer2StopRequest {
        Composer2StopRequest(
            producer: producer,
            scope: scope ?? .exact(livingRoomOnBridgeA),
            session: session,
            counter: counter)
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

    private func source(at path: String,
                        file: StaticString = #filePath,
                        line: UInt = #line) throws -> String {
        let url = repoRoot().appendingPathComponent(path)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(path)", file: file, line: line)
            throw ContractFailure.missingFile(path)
        }
        return normalized(raw)
    }

    private func contractsSource(file: StaticString = #filePath,
                                 line: UInt = #line) throws -> String {
        try source(at: contractsPath, file: file, line: line)
    }

    /// The brace-matched body of a declaration, located by an exact fragment.
    private func requireBody(_ signature: String,
                             in source: String,
                             _ path: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("\(path): declaration not found: \(signature)", file: file, line: line)
            throw ContractFailure.missingSymbol(signature)
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
            XCTFail("\(path): empty body for: \(signature)", file: file, line: line)
            throw ContractFailure.emptyBody(signature)
        }
        return joined
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

    /// The brace-matched bodies of BOTH request declarations. Guards that must
    /// apply to every request run over this, so a field cannot escape by living
    /// on the variant the guard forgot.
    private func requestBodies(file: StaticString = #filePath,
                               line: UInt = #line) throws -> [(String, String)] {
        let src = try contractsSource(file: file, line: line)
        return [
            ("Composer2IntentRequest",
             try requireBody("struct Composer2IntentRequest", in: src, contractsPath,
                             file: file, line: line)),
            ("Composer2StopRequest",
             try requireBody("struct Composer2StopRequest", in: src, contractsPath,
                             file: file, line: line)),
        ]
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Value semantics
    // ──────────────────────────────────────────────

    func testIntentRequestEqualityAndHashingAreValueSemantics() {
        let a = intentRequest()
        let b = intentRequest()
        XCTAssertEqual(a, b, "two identically built intent requests must be equal")
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1, "equal requests must collapse in a Set")

        // Every field must carry identity — a request differing in exactly one
        // of them is a different request.
        let variants: [Composer2IntentRequest] = [
            intentRequest(producer: .studio),
            intentRequest(intent: .lightState),
            intentRequest(target: .wholeSystem),
            intentRequest(transport: .selected(.rest)),
            intentRequest(session: .restTelemetry(scope: livingRoomOnBridgeA, producer: .composer)),
            intentRequest(counter: .compositionPlayback(1)),
        ]
        XCTAssertEqual(variants.count, 6, "one variant per field on the intent request")
        for variant in variants {
            XCTAssertNotEqual(a, variant, "a differing field must change identity")
        }
        XCTAssertEqual(Set(variants + [a]).count, 7,
                       "each single-field variant must be distinct from the others")
    }

    func testStopRequestEqualityAndHashingAreValueSemantics() {
        let a = stopRequest()
        let b = stopRequest()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1)

        let variants: [Composer2StopRequest] = [
            stopRequest(producer: .studio),
            stopRequest(scope: .everything),
            stopRequest(session: .entertainment(bridge: .bridge("A"),
                                                configuration: Composer2ConfigurationIdentity("c1"))),
            stopRequest(counter: .allDayPlayback(2)),
        ]
        XCTAssertEqual(variants.count, 4, "one variant per field on the stop request")
        for variant in variants {
            XCTAssertNotEqual(a, variant, "a differing field must change identity")
        }
        XCTAssertEqual(Set(variants + [a]).count, 5)
    }

    /// The envelope keeps the two variants apart. A stop is not a quieter
    /// intent, and no pair of them may ever compare equal.
    func testRequestEnvelopeKeepsIntentAndStopDistinct() {
        let intent = Composer2ConsumerRequest.intent(intentRequest())
        let stop = Composer2ConsumerRequest.stop(stopRequest())
        XCTAssertNotEqual(intent, stop, "a stop request is not an intent request")
        XCTAssertEqual(Set([intent, stop]).count, 2)

        // Same producer, same group, still two different requests.
        let sameScopeIntent = Composer2ConsumerRequest.intent(
            intentRequest(producer: .manual, target: .group(livingRoomOnBridgeA)))
        let sameScopeStop = Composer2ConsumerRequest.stop(
            stopRequest(producer: .manual, scope: .exact(livingRoomOnBridgeA)))
        XCTAssertNotEqual(sameScopeIntent, sameScopeStop,
                          "matching producer and scope must not merge the two variants")

        XCTAssertEqual(Composer2ConsumerRequest.intent(intentRequest()), intent,
                       "the envelope must not disturb the wrapped value's equality")
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Producer identity
    // ──────────────────────────────────────────────

    /// Every request names its origin with the ACCEPTED producer vocabulary.
    /// No `ProducerID`, `OwnerID`, `SourceID`, `ExecutorID`, `SubsystemID`, and
    /// no `delegatesTo` — an origin stays the origin even when another
    /// subsystem carries out the work.
    func testEveryRequestUsesTheAcceptedProducerVocabulary() throws {
        for producer in Composer2Producer.allCases {
            XCTAssertEqual(intentRequest(producer: producer).producer, producer)
            XCTAssertEqual(stopRequest(producer: producer).producer, producer)
        }
        XCTAssertEqual(Composer2Producer.allCases.count, 9,
                       "the accepted producer vocabulary is nine origins")

        let src = try contractsSource()
        for (name, body) in try requestBodies() {
            let declaration = try requireBody("struct \(name)", in: src, contractsPath)
            XCTAssertTrue(declaration.contains("let producer: Composer2Producer"),
                          "\(name) must name its origin with the accepted producer type")
            for forbidden in ["ProducerID", "OwnerID", "SourceID", "ExecutorID",
                              "SubsystemID", "delegatesTo", "executor", "subsystem"] {
                requireAbsent(forbidden, in: body,
                              "\(name) introduces no second producer identity")
            }
        }
    }

    func testRequestsDifferingOnlyByProducerAreDistinct() {
        // Two origins presenting the identical action are two requests. A
        // contract that merged them would have silently decided that origin
        // does not matter — which is exactly the arbitration question deferred.
        var seen: Set<Composer2IntentRequest> = []
        for producer in Composer2Producer.allCases {
            seen.insert(intentRequest(producer: producer))
        }
        XCTAssertEqual(seen.count, Composer2Producer.allCases.count,
                       "each origin's request must stay distinct")

        var stops: Set<Composer2StopRequest> = []
        for producer in Composer2Producer.allCases {
            stops.insert(stopRequest(producer: producer))
        }
        XCTAssertEqual(stops.count, Composer2Producer.allCases.count)
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Intent reuse
    // ──────────────────────────────────────────────

    /// Non-stop work reuses `Composer2ProducerIntent`. The audit found no
    /// semantic mismatch that a second operation enum would have resolved.
    func testIntentRequestsReuseTheAcceptedProducerIntentVocabulary() throws {
        for intent in Composer2ProducerIntent.allCases {
            XCTAssertEqual(intentRequest(intent: intent).intent, intent)
        }
        XCTAssertEqual(Set(Composer2ProducerIntent.allCases.map { intentRequest(intent: $0) }).count,
                       Composer2ProducerIntent.allCases.count,
                       "each intent kind must produce a distinct request")

        let src = try contractsSource()
        let body = try requireBody("struct Composer2IntentRequest", in: src, contractsPath)
        XCTAssertTrue(body.contains("let intent: Composer2ProducerIntent"),
                      "the intent request must reuse the accepted intent vocabulary")
    }

    /// Anti-vacuity for the claim above: the production file declares exactly
    /// the six new types and NO second operation/intent enum.
    func testNoSecondConsumerOperationEnumIsDeclared() throws {
        let src = try contractsSource()
        for declaration in newDeclarations {
            XCTAssertTrue(src.contains(declaration),
                          "expected declaration missing, this guard is stale: \(declaration)")
        }

        // Every type declared in the file, extracted exactly.
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
                       "the file must declare exactly the six approved types, found: \(declared)")

        for forbidden in ["Operation", "ConsumerIntent", "RequestKind", "ActionKind", "Verb"] {
            requireAbsent(forbidden, in: src,
                          "no second operation vocabulary may be introduced")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Target model
    // ──────────────────────────────────────────────

    func testGroupTargetPreservesBridgeIdentityAndRoomVersusZone() {
        let roomOnA = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("A"), group: .room("x")))
        let zoneOnA = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("A"), group: .zone("x")))
        let roomOnB = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("B"), group: .room("x")))

        XCTAssertNotEqual(roomOnA, zoneOnA,
                          "room and zone stay distinct, exactly as production distinguishes them")
        XCTAssertNotEqual(roomOnA, roomOnB,
                          "the same group id on two bridges is two different targets")
        XCTAssertEqual(Set([roomOnA, zoneOnA, roomOnB]).count, 3)

        // The identity survives the round trip through a request.
        guard case .group(let scope) = intentRequest(target: roomOnA).target else {
            return XCTFail("a group target must remain a group target")
        }
        XCTAssertEqual(scope.bridge, .bridge("A"))
        XCTAssertEqual(scope.group, .room("x"))
    }

    /// The bridgeless CASE can never collide with a real bridge whose id
    /// happens to be one of production's three spellings of "no bridge".
    func testGroupTargetSeparatesUnidentifiedBridgeFromLegacyAndEmptyBridgeIDs() {
        let group = Composer2GroupIdentity.room("living")
        let unidentified = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .unidentified, group: group))
        let legacy = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("legacy"), group: group))
        let empty = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge(""), group: group))

        XCTAssertNotEqual(unidentified, legacy)
        XCTAssertNotEqual(unidentified, empty)
        XCTAssertNotEqual(legacy, empty)
        XCTAssertEqual(Set([unidentified, legacy, empty]).count, 3,
                       "three spellings of bridgelessness must never collapse")

        // And the same separation must hold on a REST-light target.
        let light = Composer2RESTLightIdentity("l1")
        XCTAssertNotEqual(Composer2ConsumerTarget.restLight(bridge: .unidentified, light: light),
                          Composer2ConsumerTarget.restLight(bridge: .bridge("legacy"), light: light))
    }

    func testBridgeTargetCannotBeConfusedWithAGroupTarget() {
        let bridgeWide = Composer2ConsumerTarget.bridge(.bridge("A"))
        let groupOnSameBridge = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("A"), group: .room("A")))

        XCTAssertNotEqual(bridgeWide, groupOnSameBridge,
                          "a bridge-wide target is not a group target on that bridge")
        XCTAssertEqual(Set([bridgeWide, groupOnSameBridge]).count, 2)

        XCTAssertNotEqual(Composer2ConsumerTarget.bridge(.bridge("A")),
                          Composer2ConsumerTarget.bridge(.bridge("B")))
        XCTAssertNotEqual(Composer2ConsumerTarget.bridge(.bridge("A")),
                          Composer2ConsumerTarget.bridge(.unidentified))

        // Streaming acquisition is per-bridge in production, so a bridge target
        // must not carry a configuration — that identifies the SESSION.
        guard case .bridge(let identity) = bridgeWide else {
            return XCTFail("a bridge target must remain a bridge target")
        }
        XCTAssertEqual(identity, .bridge("A"))
    }

    func testWholeSystemTargetCannotBeConfusedWithBridgeOrGroupTargets() {
        let whole = Composer2ConsumerTarget.wholeSystem
        let anyBridge = Composer2ConsumerTarget.bridge(.unidentified)
        let anyGroup = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .unidentified, group: .room("")))

        XCTAssertNotEqual(whole, anyBridge,
                          "whole-system is not a bridge whose identity is unknown")
        XCTAssertNotEqual(whole, anyGroup,
                          "whole-system is not an unidentified group")
        XCTAssertEqual(Set([whole, anyBridge, anyGroup]).count, 3)
        XCTAssertEqual(whole, Composer2ConsumerTarget.wholeSystem)

        // It carries no payload: the paths that use it name no bridge at all.
        let src = try? contractsSource()
        XCTAssertNotNil(src)
        let declared = (src ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(declared.contains("case wholeSystem"),
                      "wholeSystem must be declared payload-free")
    }

    /// The REST namespace is preserved exactly, and the bridge travels with it —
    /// the same resource id on two bridges is two different lights.
    func testRESTLightTargetPreservesItsBridgeAndRESTResourceNamespace() {
        let id = "0b1e2c3d-4f56"
        let onA = Composer2ConsumerTarget.restLight(bridge: .bridge("A"),
                                                    light: Composer2RESTLightIdentity(id))
        let onB = Composer2ConsumerTarget.restLight(bridge: .bridge("B"),
                                                    light: Composer2RESTLightIdentity(id))
        XCTAssertNotEqual(onA, onB)

        guard case .restLight(let bridge, let light) = onA else {
            return XCTFail("a REST-light target must remain a REST-light target")
        }
        XCTAssertEqual(bridge, .bridge("A"))
        XCTAssertEqual(light.rawValue, id,
                       "the Hue resource id must survive verbatim — no normalization")
        XCTAssertEqual(Composer2RESTLightIdentity(id), Composer2RESTLightIdentity(id))
        XCTAssertNotEqual(Composer2RESTLightIdentity("1"), Composer2RESTLightIdentity("2"))
    }

    /// The 1C2 deferral holds: a REST resource id is not an Entertainment
    /// channel, and a light target never implies the group around it.
    func testRESTLightTargetNamesNoGroupAndNoEntertainmentChannel() throws {
        let light = Composer2ConsumerTarget.restLight(
            bridge: .bridge("A"), light: Composer2RESTLightIdentity("7"))
        let groupOnSameBridge = Composer2ConsumerTarget.group(
            Composer2GroupScope(bridge: .bridge("A"), group: .room("7")))

        XCTAssertNotEqual(light, groupOnSameBridge,
                          "a light target must not be confusable with a room that shares its id")
        XCTAssertNotEqual(light, Composer2ConsumerTarget.bridge(.bridge("A")))
        XCTAssertNotEqual(light, Composer2ConsumerTarget.wholeSystem)
        XCTAssertEqual(Set([light, groupOnSameBridge]).count, 2)

        let src = try contractsSource()
        let identity = try requireBody("struct Composer2RESTLightIdentity", in: src, contractsPath)
        XCTAssertTrue(identity.contains("let rawValue: String"),
                      "the REST light identity must carry a Hue resource String")
        // Never an Entertainment channel, and never a universal light id.
        for forbidden in ["UInt8", "channel", "Channel", "Composer2LightIdentity",
                          "universal", "room", "group", "Group"] {
            requireAbsent(forbidden, in: identity,
                          "the REST light identity stays in its own namespace")
        }

        // The target case itself must not carry a group alongside the light.
        let target = try requireBody("enum Composer2ConsumerTarget", in: src, contractsPath)
        let cases = caseNames(in: target)
        XCTAssertEqual(cases.count, 4, "exactly four target shapes, found: \(cases)")
        let restLightCase = try XCTUnwrap(cases.first { $0.hasPrefix("restLight") })
        requireAbsent("Composer2GroupScope", in: restLightCase,
                      "a light target must not name a containing group")
        requireAbsent("Composer2GroupIdentity", in: restLightCase,
                      "a light target must not name a containing group")
    }

    // ──────────────────────────────────────────────
    // MARK: - E. Stop requests
    // ──────────────────────────────────────────────

    func testStopRequestsUseTheAcceptedStopScopeVocabulary() throws {
        let scopes: [Composer2StopScope] = [
            .exact(livingRoomOnBridgeA),
            .anyBridgeHosting(.room("living")),
            .everything,
        ]
        for scope in scopes {
            XCTAssertEqual(stopRequest(scope: scope).scope, scope)
        }
        XCTAssertEqual(Set(scopes.map { stopRequest(scope: $0) }).count, 3)

        let src = try contractsSource()
        let body = try requireBody("struct Composer2StopRequest", in: src, contractsPath)
        XCTAssertTrue(body.contains("let scope: Composer2StopScope"),
                      "a stop must name its target with the accepted stop scope")
        // A stop says what ends, not how — no production stop path names one.
        requireAbsent("Composer2ConsumerTransportState", in: body,
                      "a stop request carries no transport")
        requireAbsent("Composer2ConsumerTarget", in: body,
                      "a stop names a stop scope, not an ordinary target")
    }

    /// The "whichever bridge hosts it" request stays separate from an exact
    /// scope whose bridge is unidentified — production spells both with a nil
    /// bridge id, and collapsing them here would re-create that ambiguity.
    func testStopScopeVariantsRemainMutuallyDistinct() {
        let group = Composer2GroupIdentity.room("living")
        let anyBridge = Composer2StopRequest(producer: .manual, scope: .anyBridgeHosting(group))
        let unidentifiedExact = Composer2StopRequest(
            producer: .manual,
            scope: .exact(Composer2GroupScope(bridge: .unidentified, group: group)))
        let everything = Composer2StopRequest(producer: .manual, scope: .everything)

        XCTAssertNotEqual(anyBridge, unidentifiedExact,
                          "an ambiguous host is not a group with no identified bridge")
        XCTAssertNotEqual(anyBridge, everything)
        XCTAssertNotEqual(unidentifiedExact, everything)
        XCTAssertEqual(Set([anyBridge, unidentifiedExact, everything]).count, 3)
    }

    // ──────────────────────────────────────────────
    // MARK: - F. Transport
    // ──────────────────────────────────────────────

    /// `selected` is a fact about THIS request instance. `notSelected` is the
    /// composition-start fact: the per-bridge gate has not run yet.
    func testTransportStateDistinguishesNotSelectedFromSelected() throws {
        XCTAssertNotEqual(Composer2ConsumerTransportState.notSelected,
                          .selected(.rest),
                          "not-yet-chosen must never equal a bound transport")
        XCTAssertEqual(Composer2ConsumerTransportState.notSelected, .notSelected)

        var states: Set<Composer2ConsumerTransportState> = [.notSelected]
        for transport in Composer2Transport.allCases {
            states.insert(.selected(transport))
        }
        XCTAssertEqual(states.count, Composer2Transport.allCases.count + 1,
                       "every transport plus the unselected state must stay distinct")

        XCTAssertNotEqual(intentRequest(transport: .notSelected),
                          intentRequest(transport: .selected(.entertainment)))
        guard case .selected(let bound) = intentRequest(transport: .selected(.rest)).transport else {
            return XCTFail("a selected transport must remain selected")
        }
        XCTAssertEqual(bound, .rest)

        let src = try contractsSource()
        let body = try requireBody("enum Composer2ConsumerTransportState", in: src, contractsPath)
        XCTAssertEqual(Set(caseNames(in: body).map { String($0.prefix(while: { $0 != "(" })) }),
                       ["notSelected", "selected"],
                       "exactly two transport states")
    }

    /// Reach is capability; a capability is not a selection. The transport
    /// state must encode no automatic case, no preference, and no fallback.
    func testTransportStateCarriesNoAutomaticOrPreferenceSemantics() throws {
        let src = try contractsSource()
        let body = try requireBody("enum Composer2ConsumerTransportState", in: src, contractsPath)
        for forbidden in ["auto", "Auto", "prefer", "Prefer", "fallback", "Fallback",
                          "priority", "rank", "order", "Order", "default", "Comparable"] {
            requireAbsent(forbidden, in: body,
                          "transport state encodes no selection policy")
        }

        // And no request may copy a registration's reachable-transport set.
        for (name, requestBody) in try requestBodies() {
            for forbidden in ["reachableTransports", "requestedTransport",
                              "Set<Composer2Transport>", "preferEntertainment"] {
                requireAbsent(forbidden, in: requestBody,
                              "\(name) states a bound transport, never reach or preference")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - G. Session identity
    // ──────────────────────────────────────────────

    /// A session field holds an ACTUAL `Composer2SessionIdentity` instance —
    /// never a `Composer2RegistrationSessionNamespace`, which names a namespace
    /// and identifies nothing.
    func testSessionIsAnActualSessionIdentityNotARegistrationNamespace() throws {
        let entertainment = Composer2SessionIdentity.entertainment(
            bridge: .bridge("A"), configuration: Composer2ConfigurationIdentity("c1"))
        let telemetry = Composer2SessionIdentity.restTelemetry(
            scope: livingRoomOnBridgeA, producer: .composer)

        XCTAssertEqual(intentRequest(session: entertainment).session, entertainment)
        XCTAssertEqual(stopRequest(session: telemetry).session, telemetry)
        XCTAssertNotEqual(intentRequest(session: entertainment),
                          intentRequest(session: telemetry))

        // The two namespaces do not share a key shape and must not merge.
        XCTAssertNotEqual(entertainment, telemetry)
        XCTAssertNotEqual(
            entertainment,
            .entertainment(bridge: .bridge("A"),
                           configuration: Composer2ConfigurationIdentity("c2")))

        for (name, body) in try requestBodies() {
            XCTAssertTrue(body.contains("let session: Composer2SessionIdentity?"),
                          "\(name) must carry an actual session identity, optionally")
            requireAbsent("Composer2RegistrationSessionNamespace", in: body,
                          "\(name) must not promote a namespace into an instance")
            requireAbsent("identityBearingSessionNamespaces", in: body,
                          "\(name) must not copy registration session capability")
        }
    }

    /// `nil` means exactly one thing: this request carries no session instance.
    /// It is not a claim about what the producer usually does — the
    /// registration already answers that, which is why it is not restated here.
    func testAbsentSessionMeansThisRequestCarriesNoSessionInstance() {
        // A composition start has no session yet: production establishes the
        // telemetry session only AFTER the per-bridge acquisition gate.
        let start = intentRequest(producer: .composer,
                                  intent: .continuousStreaming,
                                  transport: .notSelected)
        XCTAssertNil(start.session, "a start request carries no session instance")
        XCTAssertNil(start.counter, "and no counter has been assigned yet")

        // The same producer mid-session carries one. Same origin, same intent —
        // only the instance facts differ, and that difference is visible.
        let midSession = intentRequest(
            producer: .composer,
            intent: .continuousStreaming,
            transport: .selected(.entertainment),
            session: .restTelemetry(scope: livingRoomOnBridgeA, producer: .composer))
        XCTAssertNotNil(midSession.session)
        XCTAssertNotEqual(start, midSession)

        // Siri reaches Entertainment but its identity does not survive the
        // handoff, so its request bears no session. Absence is a fact here,
        // never a synthesis from what the origin could reach.
        XCTAssertNil(intentRequest(producer: .siri, intent: .continuousStreaming).session)
        XCTAssertNil(stopRequest(producer: .siri, scope: .everything).session)
    }

    // ──────────────────────────────────────────────
    // MARK: - H. Counters
    // ──────────────────────────────────────────────

    /// Counter domains stay separate. Two readings are equal only when they
    /// came from the same counter AND carry the same value.
    func testCounterMetadataUsesTheAcceptedCounterAndPreservesDomains() throws {
        let sameNumberDifferentDomains: [Composer2Counter] = [
            .compositionPlayback(3), .allDayPlayback(3), .restScopeEpoch(3),
            .bridgeNativeOwnership(3), .roomOwnership(3), .bridgeAnimationReconcile(3),
        ]
        XCTAssertEqual(Set(sameNumberDifferentDomains).count, 6,
                       "the same number in six counter domains is six readings")
        XCTAssertEqual(Set(sameNumberDifferentDomains.map { intentRequest(counter: $0) }).count, 6,
                       "a request must not flatten counter domains")

        XCTAssertEqual(intentRequest(counter: .compositionPlayback(3)).counter,
                       .compositionPlayback(3))
        XCTAssertNotEqual(intentRequest(counter: .compositionPlayback(3)),
                          intentRequest(counter: .allDayPlayback(3)))

        // The signed cases still express the negative "never seen" reading.
        XCTAssertEqual(intentRequest(counter: .roomOwnership(-1)).counter, .roomOwnership(-1))
        XCTAssertNotEqual(intentRequest(counter: .roomOwnership(-1)),
                          intentRequest(counter: .roomOwnership(1)))

        for (name, body) in try requestBodies() {
            XCTAssertTrue(body.contains("let counter: Composer2Counter?"),
                          "\(name) must carry the accepted counter, optionally")
        }
    }

    /// No generic numeric accessor and no cross-counter comparison surface.
    /// A request records a reading; it never judges one.
    func testRequestsExposeNoGenericNumericCounterAccessor() throws {
        for (name, body) in try requestBodies() {
            for forbidden in [": Int", ": UInt64", "-> Int", "numeric", "Numeric",
                              "rawValue", "Comparable", "isStale", "stale",
                              "generation", "Generation"] {
                requireAbsent(forbidden, in: body,
                              "\(name) exposes no generic counter accessor and judges no reading")
            }
            // No behavior at all: a request cannot reject its own staleness.
            for forbidden in ["func ", "var ", "if ", "guard ", "return "] {
                requireAbsent(forbidden, in: body,
                              "\(name) is a pure value with no executable behavior")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - I. Deliberate exclusions
    // ──────────────────────────────────────────────

    /// Arbitration metadata, not command payload.
    func testRequestsCarryNoCommandPayload() throws {
        for (name, body) in try requestBodies() {
            for forbidden in ["brightness", "Brightness", "xy", "mirek", "color", "Color",
                              "gradient", "Gradient", "effectParameters", "frame", "Frame",
                              "buffer", "Buffer", "scene", "Scene", "preset", "Preset",
                              "duration", "Duration", "transition", "Transition",
                              "payload", "Payload", "body", "Body", "Double", "HueLight",
                              "HueGroupedLight", "RoomDisplayItem", "turnOffLights"] {
                requireAbsent(forbidden, in: body,
                              "\(name) carries arbitration metadata, not a lighting command")
            }
        }
    }

    /// No resolution data. Whether the request is allowed, who wins, and what
    /// must yield are the resolver's questions, not the request's.
    func testRequestsCarryNoPrecedenceOrResolutionFields() throws {
        for (name, body) in try requestBodies() {
            for forbidden in ["currentOwner", "owner", "Owner", "winner", "loser",
                              "priority", "rank", "canReplace", "mayOverride",
                              "resolution", "Resolution", "verdict", "contention",
                              "Contention", "fallbackReason", "shouldStopOther",
                              "coexistence", "Comparable", "allowed", "permitted"] {
                requireAbsent(forbidden, in: body,
                              "\(name) states a request, never its resolution")
            }
        }
        // No ordering anywhere in the file: ranking requests IS precedence.
        let src = try contractsSource()
        requireAbsent("Comparable", in: src, "consumer contracts declare no ordering")
        requireAbsent("static func <", in: src, "consumer contracts declare no ordering")
    }

    /// A request references the accepted identities; it never embeds a
    /// registration snapshot or duplicates a capability set.
    func testNoRequestEmbedsARegistrationOrItsCapabilitySets() throws {
        let src = try contractsSource()
        for (name, body) in try requestBodies() {
            for forbidden in ["Composer2ProducerRegistration", "Composer2RegistrationProvenance",
                              "Composer2RegistrationScopeKind", "Composer2RegistrationStopKind",
                              "Composer2RegistrationSessionNamespace", "provenance",
                              "intents:", "scopeKinds", "stopKinds", "reachableTransports",
                              "Set<", "catalog", "Catalog"] {
                requireAbsent(forbidden, in: body,
                              "\(name) references identities, never a registration snapshot")
            }
        }
        // And no mutable registry lives here.
        for forbidden in ["static var", "var ", "mutating", "= [", "singleton", "shared"] {
            requireAbsent(forbidden, in: src,
                          "consumer contracts hold no mutable state and no registry")
        }
    }

    /// The production file is UI, network, storage, and concurrency
    /// independent — and imports nothing at all.
    func testConsumerContractSourceHasNoUIRuntimeNetworkingOrGlobalState() throws {
        let src = try contractsSource()
        XCTAssertFalse(src.isEmpty, "an empty scan proves nothing")

        for declaration in newDeclarations {
            XCTAssertTrue(src.contains(declaration),
                          "expected declaration missing, this guard is stale: \(declaration)")
        }

        for forbidden in ["SwiftUI", "UIKit", "Foundation", "URLSession", "BridgeAPIClient",
                          "HueAPIClient", "HueEntertainmentClient", "UnifiedOrchestrator",
                          "StudioViewModel", "Task", "actor ", "UserDefaults", "Keychain",
                          "NotificationCenter", "DispatchQueue", "@escaping", "@MainActor",
                          "@Observable", "Any", "[String:", "protocol ", "class ",
                          "import ", "func ", "Composer2Flag", "await", "async"] {
            requireAbsent(forbidden, in: src,
                          "the consumer contract is a pure value file")
        }

        // Anti-vacuity: the file really was read and really is the right one.
        XCTAssertTrue(src.contains("Composer2ConsumerRequest"),
                      "the scanned file must be the consumer contracts file")
    }

    // ──────────────────────────────────────────────
    // MARK: - J. No runtime consumers
    // ──────────────────────────────────────────────

    /// No RUNTIME production file consumes the consumer contracts. The only
    /// production source naming any of the six new types is the declaration
    /// file itself — this packet ships contracts, not consumers.
    func testNoProductionCodeConsumesTheConsumerContractTypes() throws {
        // Exactly two foundation files may name these types. Phase 1D adds the
        // resolver seam, whose input IS the request contract — naming it is
        // what a seam does, and it is still consumed by no runtime. Pinned by
        // exact filename: no directory-wide Composer2 exemption, because that
        // would admit the first real consumer silently.
        let definitionFile = "Composer2ConsumerContracts.swift"
        let resolverFile = "Composer2Resolver.swift"
        let foundationFiles: Set<String> = [definitionFile, resolverFile]
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
        var sawResolverFile = false
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            scannedCount += 1
            guard !foundationFiles.contains(url.lastPathComponent) else {
                if url.lastPathComponent == definitionFile { definitionSource = source }
                if url.lastPathComponent == resolverFile { sawResolverFile = true }
                continue
            }
            for type in newTypeNames where source.contains(type) {
                offenders.append("\(url.lastPathComponent): \(type)")
            }
        }

        XCTAssertGreaterThan(scannedCount, 0,
                             "an empty scan proves nothing — the walk must cover sources")
        XCTAssertTrue(sawResolverFile,
                      "the allowlisted resolver file must exist and be scanned, "
                      + "or the allowlist is silently weakening this guard")
        let definition = try XCTUnwrap(definitionSource,
                                       "the scan must have visited the consumer contracts file")
        for type in newTypeNames {
            XCTAssertTrue(definition.contains(type),
                          "\(type) must exist in the contracts file, or this guard is stale")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "no runtime consumer is authorized in Phase 1D: \(offenders)")
    }

    // ──────────────────────────────────────────────
    // MARK: - K. Accepted files remain accepted
    // ──────────────────────────────────────────────

    /// The accepted 1C2/1C2-a vocabulary is untouched by this packet: every
    /// canonical type is still declared there, and no consumer contract was
    /// smuggled in. NON-TRANSITIVE — byte-identity with the accepted ancestry
    /// is proven by git in this packet's validation.
    func testAcceptedDomainFileStillDeclaresItsVocabularyAndNoConsumerContract() throws {
        let src = try source(at: domainPath)
        let accepted = [
            "enum Composer2BridgeIdentity", "enum Composer2GroupIdentity",
            "struct Composer2GroupScope", "struct Composer2ConfigurationIdentity",
            "enum Composer2Producer", "enum Composer2Transport", "enum Composer2Counter",
            "enum Composer2SessionIdentity", "enum Composer2Contention",
            "enum Composer2Resolution", "enum Composer2StopScope",
        ]
        XCTAssertEqual(accepted.count, 11, "the accepted vocabulary is eleven types")
        for declaration in accepted {
            XCTAssertTrue(src.contains(declaration),
                          "the accepted domain declaration is missing: \(declaration)")
        }
        for type in newTypeNames {
            requireAbsent(type, in: src,
                          "no consumer contract may be added to the accepted domain file")
        }
        // The deferred universal light identity stays deferred.
        requireAbsent("LightIdentity", in: src,
                      "1C2 deferred a universal light identity and this packet keeps it deferred")
    }

    /// The accepted 1C3 registration contracts are untouched by this packet.
    func testAcceptedRegistrationFileStillDeclaresItsTypesAndNoConsumerContract() throws {
        let src = try source(at: registrationPath)
        let accepted = [
            "enum Composer2RegistrationProvenance", "enum Composer2ProducerIntent",
            "enum Composer2RegistrationScopeKind",
            "enum Composer2RegistrationSessionNamespace",
            "enum Composer2RegistrationStopKind", "struct Composer2ProducerRegistration",
            "enum Composer2ProducerRegistrationCatalog",
        ]
        XCTAssertEqual(accepted.count, 7, "the accepted registration surface is seven types")
        for declaration in accepted {
            XCTAssertTrue(src.contains(declaration),
                          "the accepted registration declaration is missing: \(declaration)")
        }
        for type in newTypeNames {
            requireAbsent(type, in: src,
                          "no consumer contract may be added to the accepted registration file")
        }
        XCTAssertEqual(Composer2ProducerRegistrationCatalog.observed.count, 9,
                       "the accepted catalog still describes exactly nine producers")
    }

    // ──────────────────────────────────────────────
    // MARK: - L. Determinism self-guard
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
