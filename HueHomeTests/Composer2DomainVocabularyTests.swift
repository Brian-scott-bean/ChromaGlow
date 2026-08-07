// Composer2DomainVocabularyTests.swift
// ChromaGlow — Composer 2 Phase 1C2.
//
// VOCABULARY ONLY. Every assertion here is about the value semantics and the
// semantic boundaries of the new canonical domain types. Nothing here starts a
// runtime, constructs an orchestrator, reads a seam, or consumes a flag — the
// behavioral claims stay in the 1B1/1B2/1C1 characterization suites and are
// deliberately not restated.
//
// What this file proves:
//   • the bridgeless condition is explicit and cannot collide with a real
//     bridge whose id happens to be one of production's sentinel spellings;
//   • two currently distinguishable resource identities stay distinguishable;
//   • producer identity carries no precedence;
//   • the transport vocabulary is domain-level, with no presentation and no
//     preference case;
//   • six counters keep their NATIVE representations and never compare equal
//     across counters;
//   • two session namespaces are preserved rather than flattened into one key;
//   • a resolution carries domain data only — it cannot fail and cannot act;
//   • the production vocabulary file is a pure value file with no consumers.
//
// Source-shape claims here are NON-TRANSITIVE, following the 1B2/1C1
// discipline: each speaks only about the brace-matched declaration it
// extracted, never about callees. Every lookup fails hard — a missing file or
// a missing declaration is a failure, never a silent skip and never a fallback
// to a whole-file substring count. Comments AND string-literal contents are
// stripped before any token assertion, so documentation prose can neither
// satisfy nor break a guard.
//
// Determinism: no timing waits of any kind. Enforced by the last test here.

import XCTest
@testable import HueHome

@MainActor
final class Composer2DomainVocabularyTests: XCTestCase {

    private var domainPath: String { "HueHome/Core/Composer2Domain.swift" }

    private enum VocabularyFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
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

    private func domainSource(file: StaticString = #filePath,
                              line: UInt = #line) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(domainPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(domainPath)", file: file, line: line)
            throw VocabularyFailure.missingFile(domainPath)
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
            XCTFail("\(domainPath): declaration not found: \(signature)", file: file, line: line)
            throw VocabularyFailure.missingSymbol(signature)
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
            XCTFail("\(domainPath): empty body for: \(signature)", file: file, line: line)
            throw VocabularyFailure.emptyBody(signature)
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
            XCTFail("\(domainPath): declaration not found: \(fragment)", file: file, line: line)
            throw VocabularyFailure.missingSymbol(fragment)
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

    private func requireContains(_ needle: String,
                                 in body: String,
                                 _ what: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertTrue(body.contains(needle),
                      "\(what): expected to find \(needle)", file: file, line: line)
    }

    private func requireAbsent(_ needle: String,
                               in body: String,
                               _ what: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertFalse(body.contains(needle),
                       "\(what): did not expect \(needle)", file: file, line: line)
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Resource identity
    // ──────────────────────────────────────────────

    /// The bridgeless condition is a case, not a sentinel — so it cannot
    /// collide with a real bridge whose id happens to be one of production's
    /// three current spellings of "no bridge".
    func testBridgelessIdentityCannotCollideWithAnyBridgeIDSpelling() {
        let unidentified = Composer2BridgeIdentity.unidentified
        let legacySpelling = Composer2BridgeIdentity.bridge("legacy")
        let emptySpelling = Composer2BridgeIdentity.bridge("")

        XCTAssertNotEqual(unidentified, legacySpelling,
                          "a bridge literally named legacy is not the bridgeless condition")
        XCTAssertNotEqual(unidentified, emptySpelling,
                          "a bridge with an empty id is not the bridgeless condition")
        XCTAssertNotEqual(legacySpelling, emptySpelling)

        XCTAssertEqual(Set([unidentified, legacySpelling, emptySpelling]).count, 3,
                       "three spellings must hash to three distinct members")

        var byIdentity: [Composer2BridgeIdentity: String] = [:]
        byIdentity[unidentified] = "unidentified"
        byIdentity[legacySpelling] = "legacy"
        byIdentity[emptySpelling] = "empty"
        XCTAssertEqual(byIdentity.count, 3, "no two spellings may share a dictionary slot")
        XCTAssertEqual(byIdentity[unidentified], "unidentified")
    }

    func testSameGroupIDOnTwoIdentifiedBridgesRemainsDistinct() {
        let group = Composer2GroupIdentity.room("living-room")
        let onA = Composer2GroupScope(bridge: .bridge("bridge-a"), group: group)
        let onB = Composer2GroupScope(bridge: .bridge("bridge-b"), group: group)

        XCTAssertNotEqual(onA, onB, "the same group id on two bridges is two scopes")
        XCTAssertEqual(Set([onA, onB]).count, 2)

        let bridgeless = Composer2GroupScope(bridge: .unidentified, group: group)
        XCTAssertNotEqual(onA, bridgeless)
        XCTAssertNotEqual(Composer2GroupScope(bridge: .bridge("legacy"), group: group),
                          bridgeless,
                          "the sentinel spelling does not become the bridgeless scope")
    }

    func testRoomAndZoneWithTheSameIDRemainDistinct() {
        let room = Composer2GroupIdentity.room("shared-id")
        let zone = Composer2GroupIdentity.zone("shared-id")

        XCTAssertNotEqual(room, zone, "room and zone are not collapsed into one id space")
        XCTAssertEqual(Set([room, zone]).count, 2)

        let bridge = Composer2BridgeIdentity.bridge("bridge-a")
        XCTAssertNotEqual(Composer2GroupScope(bridge: bridge, group: room),
                          Composer2GroupScope(bridge: bridge, group: zone))
    }

    func testGroupScopeEqualityAndHashingAreValueSemantics() {
        let one = Composer2GroupScope(bridge: .bridge("b1"), group: .room("r1"))
        let same = Composer2GroupScope(bridge: .bridge("b1"), group: .room("r1"))

        XCTAssertEqual(one, same)
        XCTAssertEqual(one.hashValue, same.hashValue)
        XCTAssertEqual(Set([one, same]).count, 1, "equal scopes collapse to one member")

        XCTAssertNotEqual(one, Composer2GroupScope(bridge: .bridge("b2"), group: .room("r1")))
        XCTAssertNotEqual(one, Composer2GroupScope(bridge: .bridge("b1"), group: .room("r2")))
        XCTAssertNotEqual(one, Composer2GroupScope(bridge: .bridge("b1"), group: .zone("r1")))
    }

    /// Configuration ids and group ids are separate namespaces: the same string
    /// in each produces identities that no session can confuse.
    func testConfigurationIdentityIsASeparateNamespaceFromGroupIdentity() {
        let config = Composer2ConfigurationIdentity("shared-id")

        XCTAssertEqual(config, Composer2ConfigurationIdentity("shared-id"))
        XCTAssertNotEqual(config, Composer2ConfigurationIdentity("other-id"))
        XCTAssertEqual(config.rawValue, "shared-id")

        let scope = Composer2GroupScope(bridge: .bridge("b1"), group: .room("shared-id"))
        let entertainment = Composer2SessionIdentity.entertainment(
            bridge: .bridge("b1"), configuration: config)
        let telemetry = Composer2SessionIdentity.restTelemetry(scope: scope, producer: .composer)

        XCTAssertNotEqual(entertainment, telemetry,
                          "one string reused across namespaces produces two identities")
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Producer identity
    // ──────────────────────────────────────────────

    func testProducerIdentitiesAreDistinctAndCoverObservedWriters() {
        let all = Composer2Producer.allCases

        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all).count, 9, "no two producer identities may collide")

        for expected: Composer2Producer in [.composer, .studio, .allDay, .automation,
                                            .widget, .siri, .watch, .manual,
                                            .foreignController] {
            XCTAssertTrue(all.contains(expected), "\(expected) must be part of the vocabulary")
        }

        // A scheduled automation firing is not a tap, and the vocabulary must
        // not let one stand in for the other: the foreground delivery path runs
        // with no interaction, and the firmware-effect write it performs is
        // reachable from no other origin.
        XCTAssertNotEqual(Composer2Producer.automation, .manual,
                          "an unattended automation is not manual control")
        XCTAssertNotEqual(Composer2Producer.automation, .allDay,
                          "two unattended origins are still two origins")
    }

    /// A producer case says where an intent came from — never who wins.
    ///
    /// NON-TRANSITIVE: this speaks only about the extracted declaration and
    /// enum body. It makes no claim about how producers are mapped onto cases.
    func testProducerVocabularyEncodesNoPrecedence() throws {
        let src = try domainSource()

        let declaration = try requireDeclaration("enum Composer2Producer", in: src)
        requireAbsent("Comparable", in: declaration, "the producer vocabulary is not ordered")

        let body = try requireBody("enum Composer2Producer", in: src)
        for ranking in ["Comparable", "priority", "rank", "wins", "beats", "precede", "outrank"] {
            requireAbsent(ranking, in: body, "producer identity carries no precedence")
        }

        XCTAssertEqual(caseNames(in: body),
                       ["composer", "studio", "allDay", "automation", "widget",
                        "siri", "watch", "manual", "foreignController"])
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Transport identity
    // ──────────────────────────────────────────────

    func testTransportCategoriesMatchObservedDeliveryPaths() throws {
        XCTAssertEqual(Composer2Transport.allCases.count, 4)
        XCTAssertEqual(Set(Composer2Transport.allCases).count, 4)

        let body = try requireBody("enum Composer2Transport", in: try domainSource())
        XCTAssertEqual(caseNames(in: body),
                       ["entertainment", "rest", "bridgeStored", "oneShot"])
    }

    /// Domain-level, not presentation. The user-facing wording for these
    /// concepts lives in the UI copy namespace and is not duplicated here.
    func testTransportVocabularyIsUIIndependent() throws {
        let body = try requireBody("enum Composer2Transport", in: try domainSource())

        for presentation in ["title", "label", "subtitle", "systemImage",
                             "Color", "Image", "Text", "localized"] {
            requireAbsent(presentation, in: body,
                          "the transport vocabulary carries no presentation")
        }
        requireAbsent("auto", in: body,
                      "a preference case would encode transport-selection policy")
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Staleness counters
    // ──────────────────────────────────────────────

    /// Production's six counters are never compared to each other. Two of them
    /// are even stamped under the same key type, so a reading carries the
    /// counter it came from and cross-counter equality is impossible.
    func testCountersFromDifferentCountersAreNeverEqual() {
        let value = 7
        let room = Composer2Counter.roomOwnership(value)
        let native = Composer2Counter.bridgeNativeOwnership(value)
        let playback = Composer2Counter.compositionPlayback(value)
        let allDay = Composer2Counter.allDayPlayback(value)
        let reconcile = Composer2Counter.bridgeAnimationReconcile(value)
        let epoch = Composer2Counter.restScopeEpoch(UInt64(value))

        XCTAssertNotEqual(room, native,
                          "two counters under the same key type are not interchangeable")
        XCTAssertNotEqual(playback, allDay)
        XCTAssertNotEqual(reconcile, epoch)
        XCTAssertEqual(Set([room, native, playback, allDay, reconcile, epoch]).count, 6,
                       "one reading per counter, six distinct members")

        XCTAssertEqual(room, Composer2Counter.roomOwnership(value),
                       "same counter and same value is the only equality")
        XCTAssertNotEqual(room, Composer2Counter.roomOwnership(value + 1))
    }

    /// Each case carries its counter's own native type, so no reading is
    /// widened, narrowed, or sign-converted to fit a shared field.
    func testCounterCasesPreserveTheirNativeUnderlyingTypes() {
        let large: UInt64 = 4_294_967_296
        guard case .restScopeEpoch(let readBack) = Composer2Counter.restScopeEpoch(large) else {
            return XCTFail("the epoch case must carry its unsigned payload")
        }
        XCTAssertEqual(readBack, large, "an epoch past 32 bits survives without narrowing")

        guard case .bridgeAnimationReconcile(let neverSeen)
                = Composer2Counter.bridgeAnimationReconcile(-1) else {
            return XCTFail("the reconcile case must carry its signed payload")
        }
        XCTAssertEqual(neverSeen, -1,
                       "the negative never-seen value an unsigned field could not hold")
        XCTAssertNotEqual(Composer2Counter.bridgeAnimationReconcile(-1),
                          Composer2Counter.bridgeAnimationReconcile(0),
                          "the never-seen value is not the zero reading")
    }

    /// No shared numeric accessor: exposing one would hand callers back the
    /// cross-counter comparison this type exists to refuse.
    func testCounterExposesNoCommonNumericAccessor() throws {
        let body = try requireBody("enum Composer2Counter", in: try domainSource())

        for coercion in ["var value", "rawValue", "Int(", "UInt64(",
                         "numericCast", "truncating", "init(exactly"] {
            requireAbsent(coercion, in: body,
                          "no accessor may re-enable cross-counter comparison")
        }

        XCTAssertEqual(caseNames(in: body),
                       ["compositionPlayback(Int)", "allDayPlayback(Int)",
                        "restScopeEpoch(UInt64)", "bridgeNativeOwnership(Int)",
                        "roomOwnership(Int)", "bridgeAnimationReconcile(Int)"])
    }

    // ──────────────────────────────────────────────
    // MARK: - E. Session identity
    // ──────────────────────────────────────────────

    /// The two observed session namespaces do not share a key shape, and
    /// neither is flattened into the other.
    func testSessionNamespacesNeverCompareEqual() {
        let bridge = Composer2BridgeIdentity.bridge("bridge-a")
        let entertainment = Composer2SessionIdentity.entertainment(
            bridge: bridge, configuration: Composer2ConfigurationIdentity("area-1"))
        let telemetry = Composer2SessionIdentity.restTelemetry(
            scope: Composer2GroupScope(bridge: bridge, group: .room("area-1")),
            producer: .composer)

        XCTAssertNotEqual(entertainment, telemetry,
                          "an entertainment session and a telemetry session are not one key")
        XCTAssertEqual(Set([entertainment, telemetry]).count, 2)
    }

    func testEntertainmentSessionIdentityIsKeyedByBridgeAndConfiguration() {
        let config = Composer2ConfigurationIdentity("area-1")
        let onA = Composer2SessionIdentity.entertainment(bridge: .bridge("a"),
                                                         configuration: config)
        let onB = Composer2SessionIdentity.entertainment(bridge: .bridge("b"),
                                                         configuration: config)

        XCTAssertNotEqual(onA, onB,
                          "the same configuration observed on another bridge is another session")
        XCTAssertNotEqual(onA, Composer2SessionIdentity.entertainment(
            bridge: .bridge("a"), configuration: Composer2ConfigurationIdentity("area-2")))
        XCTAssertEqual(onA, Composer2SessionIdentity.entertainment(
            bridge: .bridge("a"), configuration: Composer2ConfigurationIdentity("area-1")))
    }

    func testRestTelemetrySessionIdentityIsKeyedByScopeAndProducer() {
        let scope = Composer2GroupScope(bridge: .bridge("a"), group: .room("r1"))
        let byComposer = Composer2SessionIdentity.restTelemetry(scope: scope, producer: .composer)
        let byStudio = Composer2SessionIdentity.restTelemetry(scope: scope, producer: .studio)

        XCTAssertNotEqual(byComposer, byStudio,
                          "the same scope written by two producers is two sessions")

        let otherScope = Composer2GroupScope(bridge: .bridge("b"), group: .room("r1"))
        XCTAssertNotEqual(byComposer, Composer2SessionIdentity.restTelemetry(
            scope: otherScope, producer: .composer))
        XCTAssertEqual(byComposer, Composer2SessionIdentity.restTelemetry(
            scope: scope, producer: .composer))
    }

    // ──────────────────────────────────────────────
    // MARK: - F. Contention and resolution
    // ──────────────────────────────────────────────

    func testContentionReasonsAreDistinctFacts() {
        let byStudio = Composer2Contention.heldByProducer(.studio)
        let byForeign = Composer2Contention.heldByProducer(.foreignController)

        XCTAssertNotEqual(byStudio, byForeign,
                          "one spelling carries who holds the scope, foreign controllers included")

        let all: [Composer2Contention] = [
            byStudio, byForeign,
            .transportUnavailable(.entertainment),
            .transportUnavailable(.rest),
            .capacityInsufficient,
            .evidenceUnreadable,
            .superseded
        ]
        XCTAssertEqual(Set(all).count, 7, "every contention fact is distinct")
        XCTAssertNotEqual(Composer2Contention.capacityInsufficient,
                          Composer2Contention.evidenceUnreadable,
                          "unknown capacity is not insufficient capacity")
    }

    func testResolutionValuesCarryOnlyDomainData() {
        let proceed = Composer2Resolution.proceed
        let nothing = Composer2Resolution.nothingToDo
        let release = Composer2Resolution.requiresRelease(of: .studio, because: .superseded)
        let ask = Composer2Resolution.requiresUserDecision(
            about: .heldByProducer(.foreignController))
        let refuse = Composer2Resolution.refuse(because: .capacityInsufficient)
        let unknown = Composer2Resolution.undetermined(.evidenceUnreadable)

        XCTAssertEqual(Set([proceed, nothing, release, ask, refuse, unknown]).count, 6)
        XCTAssertEqual(release, Composer2Resolution.requiresRelease(of: .studio,
                                                                   because: .superseded))
        XCTAssertNotEqual(release, Composer2Resolution.requiresRelease(of: .composer,
                                                                      because: .superseded))
        XCTAssertNotEqual(release, Composer2Resolution.requiresRelease(of: .studio,
                                                                      because: .capacityInsufficient))
        XCTAssertNotEqual(refuse, unknown,
                          "a refusal and an unresolved read are different answers")
    }

    /// Resolving cannot fail and cannot act; only acting on a resolution can.
    ///
    /// NON-TRANSITIVE: speaks only about the extracted enum body.
    func testResolutionOmitsExecutionOutcomes() throws {
        let body = try requireBody("enum Composer2Resolution", in: try domainSource())

        for execution in ["failed", "message", "Error", "Task", "->", "client", "retry"] {
            requireAbsent(execution, in: body,
                          "a resolution carries no execution outcome")
        }

        XCTAssertEqual(caseNames(in: body),
                       ["proceed", "nothingToDo",
                        "requiresRelease(of: Composer2Producer, because: Composer2Contention)",
                        "requiresUserDecision(about: Composer2Contention)",
                        "refuse(because: Composer2Contention)",
                        "undetermined(Composer2Contention)"])
    }

    // ──────────────────────────────────────────────
    // MARK: - G. Stop targeting
    // ──────────────────────────────────────────────

    /// Production spells two different conditions with one nil bridge id.
    /// They are separated here.
    func testUnspecifiedStopBridgeIsDistinctFromBridgelessScope() {
        let group = Composer2GroupIdentity.room("r1")
        let unspecifiedBridge = Composer2StopScope.anyBridgeHosting(group)
        let bridgelessScope = Composer2StopScope.exact(
            Composer2GroupScope(bridge: .unidentified, group: group))

        XCTAssertNotEqual(unspecifiedBridge, bridgelessScope,
                          "'whichever bridge hosts it' is not 'the group with no bridge'")
        XCTAssertNotEqual(unspecifiedBridge, Composer2StopScope.exact(
            Composer2GroupScope(bridge: .bridge("legacy"), group: group)))
        XCTAssertEqual(Set([unspecifiedBridge, bridgelessScope, .everything]).count, 3)
    }

    // ──────────────────────────────────────────────
    // MARK: - H. Structural guards
    // ──────────────────────────────────────────────

    /// The canonical vocabulary is a pure value file: no imports at all, no UI,
    /// no concurrency, no networking, no persistence, no global state.
    func testComposer2DomainSourceHasNoUIRuntimeOrGlobalState() throws {
        let src = try domainSource()

        XCTAssertFalse(src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty read proves nothing")
        requireContains("enum Composer2BridgeIdentity", in: src, "the domain file was read")
        requireContains("enum Composer2Resolution", in: src, "the domain file was read")

        for forbidden in ["import ", "SwiftUI", "UIKit", "Task", "URLSession",
                          "UserDefaults", "Keychain", "DispatchQueue", "NotificationCenter",
                          "actor ", "class ", "static var", "shared", "os_log", "print("] {
            requireAbsent(forbidden, in: src, "the canonical vocabulary is a pure value file")
        }
    }

    /// No production code consumes the vocabulary in this packet: the only
    /// production source naming any canonical type is its own definition.
    func testNoProductionCodeReferencesTheNewVocabularyYet() throws {
        let canonicalTypes = [
            "Composer2BridgeIdentity", "Composer2GroupIdentity", "Composer2GroupScope",
            "Composer2ConfigurationIdentity", "Composer2Producer", "Composer2Transport",
            "Composer2Counter", "Composer2SessionIdentity", "Composer2Contention",
            "Composer2Resolution", "Composer2StopScope"
        ]

        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let productionRoot = testsDir.deletingLastPathComponent()
            .appendingPathComponent("HueHome")
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
            guard url.lastPathComponent != "Composer2Domain.swift" else {
                definitionSource = source
                continue
            }
            for type in canonicalTypes where source.contains(type) {
                offenders.append("\(url.lastPathComponent): \(type)")
            }
        }

        XCTAssertGreaterThan(scannedCount, 0,
                             "an empty scan proves nothing — the walk must cover sources")
        let definition = try XCTUnwrap(definitionSource,
                                       "the scan must have visited the domain file itself")
        for type in canonicalTypes {
            XCTAssertTrue(definition.contains(type),
                          "\(type) must exist in the domain file, or this guard is stale")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "no consumer is authorized in Phase 1C2: \(offenders)")
    }

    // ──────────────────────────────────────────────
    // MARK: - I. Determinism self-guard
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
