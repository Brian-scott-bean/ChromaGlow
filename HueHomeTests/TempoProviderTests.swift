// TempoProviderTests.swift
// HueHome Pro — Unit Tests
//
// TIDAL + GetSongBPM providers (music integration R3) on fixture
// transports: request shapes, token caching, JSON:API / two-step decode,
// no-result tolerance, and keyless deactivation. No network ever.

import XCTest
@testable import HueHome

// MARK: - Fixture transport

private final class FixtureTransport: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    /// URL-substring → (status, body). First match wins, in insertion order.
    private var routes: [(match: String, status: Int, body: String)] = []

    func route(_ match: String, status: Int = 200, body: String) {
        routes.append((match, status, body))
    }

    var transport: TempoTransport {
        { [self] request in
            lock.lock()
            requests.append(request)
            lock.unlock()
            let url = request.url!.absoluteString
            guard let route = routes.first(where: { url.contains($0.match) }) else {
                throw TempoProviderError.badResponse
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(route.body.utf8), response)
        }
    }
}

// MARK: - TIDAL

final class TIDALTempoProviderTests: XCTestCase {

    private let tokenBody = #"{"access_token": "tok123", "expires_in": 3600}"#
    private let tracksBody = #"{"data": [{"attributes": {"bpm": 122.0, "isrc": "QM123"}}]}"#

    private func makeProvider(_ fixture: FixtureTransport) -> TIDALTempoProvider {
        TIDALTempoProvider(clientID: "id", clientSecret: "secret",
                           countryCode: "US", transport: fixture.transport)!
    }

    func testKeylessInitReturnsNil() {
        XCTAssertNil(TIDALTempoProvider(clientID: "", clientSecret: "", transport: { _ in
            throw TempoProviderError.badResponse
        }))
    }

    func testISRCLookupReturnsBPM() async throws {
        let fixture = FixtureTransport()
        fixture.route("auth.tidal.com", body: tokenBody)
        fixture.route("openapi.tidal.com/v2/tracks", body: tracksBody)
        let bpm = try await makeProvider(fixture)
            .tempo(for: TempoQuery(track: NowPlayingTrack(service: .appleMusic, title: "T",
                                                          artist: "A", isrc: "QM123")))
        XCTAssertEqual(bpm, 122.0)
        // Auth used basic credentials; the lookup carried the bearer + ISRC filter.
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("filter%5Bisrc%5D=QM123"))
    }

    func testTokenIsCachedAcrossLookups() async throws {
        let fixture = FixtureTransport()
        fixture.route("auth.tidal.com", body: tokenBody)
        fixture.route("openapi.tidal.com/v2/tracks", body: tracksBody)
        let provider = makeProvider(fixture)
        let query = TempoQuery(track: NowPlayingTrack(service: .appleMusic, title: "T",
                                                      artist: "A", isrc: "QM123"))
        _ = try await provider.tempo(for: query)
        _ = try await provider.tempo(for: query)
        let authCalls = fixture.requests.filter { $0.url!.absoluteString.contains("auth.tidal.com") }
        XCTAssertEqual(authCalls.count, 1, "a valid token must be reused")
    }

    func testNoISRCSkipsWithoutNetwork() async throws {
        let fixture = FixtureTransport()
        let bpm = try await makeProvider(fixture)
            .tempo(for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "T", artist: "A")))
        XCTAssertNil(bpm)
        XCTAssertTrue(fixture.requests.isEmpty, "TIDAL is an ISRC join — no ISRC, no request")
    }

    func testMissingBPMFieldYieldsNil() async throws {
        let fixture = FixtureTransport()
        fixture.route("auth.tidal.com", body: tokenBody)
        fixture.route("openapi.tidal.com/v2/tracks", body: #"{"data": [{"attributes": {}}]}"#)
        let bpm = try await makeProvider(fixture)
            .tempo(for: TempoQuery(track: NowPlayingTrack(service: .appleMusic, title: "T",
                                                          artist: "A", isrc: "QM123")))
        XCTAssertNil(bpm, "bpm is optional per the live spec — absent must mean nil, not a throw")
    }

    func testHTTPErrorThrowsSoResolverFallsThrough() async {
        let fixture = FixtureTransport()
        fixture.route("auth.tidal.com", body: tokenBody)
        fixture.route("openapi.tidal.com/v2/tracks", status: 429, body: "{}")
        do {
            _ = try await makeProvider(fixture)
                .tempo(for: TempoQuery(track: NowPlayingTrack(service: .appleMusic, title: "T",
                                                              artist: "A", isrc: "QM123")))
            XCTFail("429 must throw")
        } catch { /* expected: resolver moves to the next provider */ }
    }
}

// MARK: - GetSongBPM

final class GetSongBPMProviderTests: XCTestCase {

    func testKeylessInitReturnsNil() {
        XCTAssertNil(GetSongBPMProvider(apiKey: "", transport: { _ in
            throw TempoProviderError.badResponse
        }))
    }

    func testTwoStepLookupReturnsTempo() async throws {
        let fixture = FixtureTransport()
        fixture.route("/search/", body: #"{"search": [{"id": "song99"}]}"#)
        fixture.route("/song/", body: #"{"song": {"tempo": "118"}}"#)
        let provider = GetSongBPMProvider(apiKey: "key", transport: fixture.transport)!
        let bpm = try await provider.tempo(
            for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "Golden Hour",
                                                   artist: "Ava Lane")))
        XCTAssertEqual(bpm, 118)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("id=song99"))
    }

    func testNoResultObjectShapeYieldsNilNotThrow() async throws {
        // The API returns an OBJECT under "search" when nothing matches.
        let fixture = FixtureTransport()
        fixture.route("/search/", body: #"{"search": {"error": "no result"}}"#)
        let provider = GetSongBPMProvider(apiKey: "key", transport: fixture.transport)!
        let bpm = try await provider.tempo(
            for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "X", artist: "Y")))
        XCTAssertNil(bpm)
        XCTAssertEqual(fixture.requests.count, 1, "no hit → no detail call")
    }

    func testUnparseableTempoStringYieldsNil() async throws {
        let fixture = FixtureTransport()
        fixture.route("/search/", body: #"{"search": [{"id": "song99"}]}"#)
        fixture.route("/song/", body: #"{"song": {"tempo": "unknown"}}"#)
        let provider = GetSongBPMProvider(apiKey: "key", transport: fixture.transport)!
        let bpm = try await provider.tempo(
            for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "X", artist: "Y")))
        XCTAssertNil(bpm)
    }
}

// MARK: - Assembly

final class TempoProviderAssemblyTests: XCTestCase {
    func testKeylessBuildShipsNoLiveProviders() {
        // With TempoProviderKeys empty (the committed state), the chain is
        // empty and the resolver runs hint/cache/live-estimate only.
        if TempoProviderKeys.tidalClientID.isEmpty && TempoProviderKeys.getSongBPMKey.isEmpty {
            XCTAssertTrue(TrackTempoResolver.liveProviders().isEmpty)
        } else {
            XCTAssertFalse(TrackTempoResolver.liveProviders().isEmpty,
                           "keys are present — providers must activate")
        }
    }
}
