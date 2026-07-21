// TempoProviderTests.swift
// HueHome Pro — Unit Tests
//
// GetSongBPM provider (music integration R3, revised R7 — TIDAL removed on
// verified terms grounds) on fixture transports: request shapes, the
// corrected api.getsong.co host, two-step decode, no-result tolerance, and
// keyless deactivation. No network ever.

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

// MARK: - GetSongBPM

final class GetSongBPMProviderTests: XCTestCase {

    func testKeylessInitReturnsNil() {
        XCTAssertNil(GetSongBPMProvider(apiKey: "", transport: { _ in
            throw TempoProviderError.badResponse
        }))
    }

    func testTwoStepLookupReturnsTempoFromCorrectHost() async throws {
        let fixture = FixtureTransport()
        fixture.route("/search/", body: #"{"search": [{"id": "song99"}]}"#)
        fixture.route("/song/", body: #"{"song": {"tempo": "118"}}"#)
        let provider = GetSongBPMProvider(apiKey: "key", transport: fixture.transport)!
        let bpm = try await provider.tempo(
            for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "Golden Hour",
                                                   artist: "Ava Lane")))
        XCTAssertEqual(bpm, 118)
        XCTAssertEqual(fixture.requests.count, 2)
        // R7: the docs' api.getsongbpm.com host is wrong — api.getsong.co is live.
        for request in fixture.requests {
            XCTAssertEqual(request.url?.host, "api.getsong.co")
        }
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

    func testHTTPErrorThrowsSoResolverFallsThrough() async {
        let fixture = FixtureTransport()
        fixture.route("/search/", status: 429, body: "{}")
        let provider = GetSongBPMProvider(apiKey: "key", transport: fixture.transport)!
        do {
            _ = try await provider.tempo(
                for: TempoQuery(track: NowPlayingTrack(service: .demo, title: "X", artist: "Y")))
            XCTFail("429 must throw")
        } catch { /* expected: resolver falls to the live estimate */ }
    }
}

// MARK: - Assembly

final class TempoProviderAssemblyTests: XCTestCase {
    func testKeylessBuildShipsNoLiveProviders() {
        // With TempoProviderKeys empty (the committed state), the chain is
        // empty and the resolver runs hint/cache/live-estimate only.
        if TempoProviderKeys.getSongBPMKey.isEmpty {
            XCTAssertTrue(TrackTempoResolver.liveProviders().isEmpty)
        } else {
            XCTAssertFalse(TrackTempoResolver.liveProviders().isEmpty,
                           "key present — the provider must activate")
        }
    }
}
