// TrackTempoResolverTests.swift
// HueHome Pro — Unit Tests
//
// TrackTempoResolver (music integration R1): resolution order
// (hint → cache → providers → live estimate), the persistent cache codec,
// the user-facing lookup toggle, and garbage-data rejection. All providers
// are mocks; the cache lives in a per-test temp file.

import XCTest
@testable import HueHome

// MARK: - Mocks

private final class MockTempoProvider: TempoProvider, @unchecked Sendable {
    let id: String
    let result: Double?
    let error: Error?
    private(set) var calls: [TempoQuery] = []

    init(id: String, result: Double? = nil, error: Error? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    func tempo(for query: TempoQuery) async throws -> Double? {
        calls.append(query)
        if let error { throw error }
        return result
    }
}

private struct StubError: Error {}

// MARK: - Tests

@MainActor
final class TrackTempoResolverTests: XCTestCase {

    private var tempURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "TrackTempoResolverTests"

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-cache-\(UUID().uuidString).json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func resolver(
        providers: [TempoProvider] = [],
        live: @escaping @Sendable () -> (bpm: Double, confidence: Double) = { (0, 0) },
        now: @escaping () -> Date = Date.init
    ) -> TrackTempoResolver {
        TrackTempoResolver(providers: providers, fileURL: tempURL,
                           defaults: defaults, liveEstimate: live, now: now)
    }

    private func track(title: String = "Song", artist: String = "Artist",
                       isrc: String? = nil, amID: String? = nil,
                       hint: Double? = nil) -> NowPlayingTrack {
        NowPlayingTrack(service: .demo, title: title, artist: artist,
                        isrc: isrc, appleMusicID: amID, tempoHint: hint)
    }

    // MARK: Resolution order

    func testHintShortCircuitsProviders() async {
        let provider = MockTempoProvider(id: "p1", result: 100)
        let r = resolver(providers: [provider])
        let resolved = await r.resolve(for: track(hint: 96))
        XCTAssertEqual(resolved, ResolvedTempo(bpm: 96, confidence: 1.0, origin: .hint))
        XCTAssertTrue(provider.calls.isEmpty, "a source-supplied tempo must skip all lookups")
    }

    func testProviderOrderFirstHitWins() async {
        let miss  = MockTempoProvider(id: "miss", result: nil)
        let fail  = MockTempoProvider(id: "fail", error: StubError())
        let hit   = MockTempoProvider(id: "hit", result: 124)
        let never = MockTempoProvider(id: "never", result: 90)
        let r = resolver(providers: [miss, fail, hit, never])
        let resolved = await r.resolve(for: track(isrc: "QMJMT1701229"))
        XCTAssertEqual(resolved, ResolvedTempo(bpm: 124, confidence: 1.0, origin: .provider("hit")))
        XCTAssertEqual(miss.calls.count, 1)
        XCTAssertEqual(fail.calls.count, 1, "a throwing provider falls through, not out")
        XCTAssertEqual(never.calls.count, 0, "providers after the first hit are never called")
    }

    func testOutOfRangeProviderResultIsRejected() async {
        let garbage = MockTempoProvider(id: "garbage", result: 4000)
        let sane = MockTempoProvider(id: "sane", result: 118)
        let r = resolver(providers: [garbage, sane])
        let resolved = await r.resolve(for: track())
        XCTAssertEqual(resolved?.origin, .provider("sane"))
        XCTAssertEqual(resolved?.bpm, 118)
    }

    func testLiveEstimateIsLastResort() async {
        let miss = MockTempoProvider(id: "miss", result: nil)
        let r = resolver(providers: [miss], live: { (87, 0.6) })
        let resolved = await r.resolve(for: track())
        XCTAssertEqual(resolved, ResolvedTempo(bpm: 87, confidence: 0.6, origin: .liveEstimate))
    }

    func testNoSourcesAtAllReturnsNil() async {
        let r = resolver(live: { (0, 0) })
        let resolved = await r.resolve(for: track())
        XCTAssertNil(resolved)
    }

    // MARK: Cache

    func testCacheHitSkipsProviders() async {
        let provider = MockTempoProvider(id: "p1", result: 124)
        let r = resolver(providers: [provider])
        _ = await r.resolve(for: track(isrc: "X1"))
        let second = await r.resolve(for: track(isrc: "X1"))
        XCTAssertEqual(provider.calls.count, 1, "second resolve must come from the cache")
        XCTAssertEqual(second, ResolvedTempo(bpm: 124, confidence: 1.0, origin: .cached("p1")))
    }

    func testCachePersistsAcrossInstances() async {
        let provider = MockTempoProvider(id: "p1", result: 124)
        _ = await resolver(providers: [provider]).resolve(for: track(isrc: "X1"))

        let fresh = MockTempoProvider(id: "p1", result: 99)
        let resolved = await resolver(providers: [fresh]).resolve(for: track(isrc: "X1"))
        XCTAssertEqual(resolved?.bpm, 124, "cache file must round-trip across resolver instances")
        XCTAssertEqual(resolved?.origin, .cached("p1"))
        XCTAssertTrue(fresh.calls.isEmpty)
    }

    func testCorruptCacheFileStartsClean() async {
        try? Data("not json{{{".utf8).write(to: tempURL)
        let provider = MockTempoProvider(id: "p1", result: 124)
        let r = resolver(providers: [provider])
        let resolved = await r.resolve(for: track(isrc: "X1"))
        XCTAssertEqual(resolved?.bpm, 124, "a corrupt cache must never fail resolution")
        XCTAssertEqual(r.cachedTempoCount, 1)
    }

    func testCacheEvictsOldestPastCap() async {
        let provider = MockTempoProvider(id: "p1", result: 124)
        var tick = 0.0
        let r = resolver(providers: [provider], now: {
            tick += 1
            return Date(timeIntervalSinceReferenceDate: tick)
        })
        for i in 0..<502 {
            _ = await r.resolve(for: track(isrc: "TRACK\(i)"))
        }
        XCTAssertEqual(r.cachedTempoCount, 500, "cache must stay bounded")
        // The oldest entries were evicted — resolving TRACK0 hits the provider again.
        let before = provider.calls.count
        _ = await r.resolve(for: track(isrc: "TRACK0"))
        XCTAssertEqual(provider.calls.count, before + 1)
    }

    // MARK: Toggle

    func testLookupDisabledSkipsProvidersButKeepsLiveEstimate() async {
        defaults.set(false, forKey: TrackTempoResolver.lookupEnabledKey)
        let provider = MockTempoProvider(id: "p1", result: 124)
        let r = resolver(providers: [provider], live: { (91, 0.5) })
        let resolved = await r.resolve(for: track())
        XCTAssertTrue(provider.calls.isEmpty, "the toggle must gate every network lookup")
        XCTAssertEqual(resolved?.origin, .liveEstimate)
    }

    func testLookupDefaultsToEnabled() {
        XCTAssertTrue(resolver().lookupEnabled)
    }

    // MARK: Key derivation

    func testCacheKeyPrefersISRCThenIDThenMetadata() {
        XCTAssertEqual(
            TempoQuery(track: track(isrc: "QM123", amID: "555")).cacheKey, "isrc:QM123")
        XCTAssertEqual(
            TempoQuery(track: track(amID: "555")).cacheKey, "am:555")
        XCTAssertEqual(
            TempoQuery(track: track(title: "Golden Hour", artist: "Ava Lane")).cacheKey,
            "meta:ava lane|golden hour")
    }

    // MARK: Negative cache + 429 cooldown (audit R9 follow-up)

    func testDefinitiveMissIsNegativeCached() async {
        let provider = MockTempoProvider(id: "p1", result: nil)   // reachable, no data
        let r = resolver(providers: [provider])
        _ = await r.resolve(for: track())
        _ = await r.resolve(for: track())
        XCTAssertEqual(provider.calls.count, 1,
                       "a definitive miss must not re-query on every track change")
        XCTAssertEqual(r.cachedMissCount, 1)
    }

    func testMissRetriesAfterTTLAndHitClearsIt() async {
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let missing = MockTempoProvider(id: "p1", result: nil)
        let rA = resolver(providers: [missing], now: { fakeNow })
        _ = await rA.resolve(for: track())
        XCTAssertEqual(rA.cachedMissCount, 1)

        fakeNow += TrackTempoResolver.missTTL + 60
        let found = MockTempoProvider(id: "p1", result: 120)
        let rB = resolver(providers: [found], now: { fakeNow })
        let resolved = await rB.resolve(for: track())
        XCTAssertEqual(found.calls.count, 1, "an expired miss retries the provider")
        XCTAssertEqual(resolved?.bpm, 120)
        XCTAssertEqual(rB.cachedMissCount, 0, "a hit supersedes the old miss")
        XCTAssertEqual(rB.cachedTempoCount, 1)
    }

    func testTransportErrorIsNotNegativeCached() async {
        let flaky = MockTempoProvider(id: "p1", error: StubError())
        let r = resolver(providers: [flaky])
        _ = await r.resolve(for: track())
        _ = await r.resolve(for: track())
        XCTAssertEqual(flaky.calls.count, 2,
                       "network trouble is not a negative signal — retry next track")
        XCTAssertEqual(r.cachedMissCount, 0)
    }

    func testRateLimitedProviderCoolsDownThenRetries() async {
        var fakeNow = Date(timeIntervalSince1970: 2_000_000)
        let limited = MockTempoProvider(id: "p1", error: TempoProviderError.rateLimited)
        let r = resolver(providers: [limited], now: { fakeNow })
        _ = await r.resolve(for: track(title: "A"))
        _ = await r.resolve(for: track(title: "B"))
        XCTAssertEqual(limited.calls.count, 1,
                       "an exhausted quota must not be hammered on the next track")
        XCTAssertEqual(r.cachedMissCount, 0, "429 is not a per-track miss")

        fakeNow += TrackTempoResolver.rateLimitCooldown + 60
        _ = await r.resolve(for: track(title: "C"))
        XCTAssertEqual(limited.calls.count, 2, "cooldown over — provider consulted again")
    }

    func testLegacyCacheFileWithoutMissesDecodes() async throws {
        let legacy = #"{"entries":{"meta:artist|song":{"bpm":120,"providerID":"old","storedAt":0}}}"#
        try legacy.data(using: .utf8)!.write(to: tempURL)
        let r = resolver()
        let resolved = await r.resolve(for: track())
        XCTAssertEqual(resolved?.bpm, 120, "pre-misses cache files must decode cleanly")
        XCTAssertEqual(r.cachedMissCount, 0)
    }

    func testOutOfRangeCachedEntryIsDroppedAndReResolved() async throws {
        let poisoned = #"{"entries":{"meta:artist|song":{"bpm":500,"providerID":"old","storedAt":0}}}"#
        try poisoned.data(using: .utf8)!.write(to: tempURL)
        let provider = MockTempoProvider(id: "p1", result: 120)
        let r = resolver(providers: [provider])
        let resolved = await r.resolve(for: track())
        XCTAssertEqual(resolved?.bpm, 120,
                       "a cached BPM the clock would reject must be re-resolved, not served")
        XCTAssertEqual(provider.calls.count, 1)
    }
}
