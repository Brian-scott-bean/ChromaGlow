// SpotifyAuthTests.swift
// HueHome Pro — Unit Tests
//
// Spotify PKCE + client seams (music integration R5): RFC 7636 vectors,
// authorize-URL hygiene (the verifier must NEVER appear in a URL), token
// decode, currently-playing mapping, 204/401 handling, and the Keychain
// account-name pins (H-03/H-04 discipline: these strings are load-bearing
// for scrub coverage and must never drift).

import XCTest
@testable import HueHome

final class SpotifyPKCETests: XCTestCase {

    func testChallengeMatchesRFC7636Vector() {
        // RFC 7636 appendix B reference vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(SpotifyPKCE.codeChallenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierShapeIsRFCCompliant() {
        let verifier = SpotifyPKCE.codeVerifier()
        XCTAssertEqual(verifier.count, 86, "64 octets base64url = 86 chars (43–128 allowed)")
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(verifier, SpotifyPKCE.codeVerifier(), "verifiers are random")
    }

    func testAuthorizeURLCarriesChallengeNeverVerifier() {
        let verifier = SpotifyPKCE.codeVerifier()
        let url = SpotifyPKCE.authorizeURL(
            clientID: "abc123",
            challenge: SpotifyPKCE.codeChallenge(for: verifier)
        ).absoluteString
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("client_id=abc123"))
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertFalse(url.contains(verifier), "the verifier is a secret until the exchange")
        XCTAssertTrue(url.contains("user-read-currently-playing"))
    }

    func testTokenResponseDecodes() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#
        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, SpotifyTokenResponse(access_token: "AT", refresh_token: "RT",
                                                     expires_in: 3600))
    }

    func testKeychainAccountNamesAreStable() {
        // Scrub/secret discipline keys on these exact strings.
        XCTAssertEqual(SpotifyAuthService.accessTokenAccount, "spotify_access_token")
        XCTAssertEqual(SpotifyAuthService.refreshTokenAccount, "spotify_refresh_token")
        XCTAssertEqual(SpotifyKeys.redirectURI, "chromaglow://spotify-callback",
                       "must match Brian's dashboard registration verbatim")
    }
}

// MARK: - Client

final class SpotifyAPIClientTests: XCTestCase {

    private let playingBody = #"""
    {"progress_ms": 42500, "is_playing": true,
     "item": {"id": "track1", "name": "Golden Hour", "duration_ms": 214980,
              "artists": [{"name": "Ava Lane"}, {"name": "Kai"}],
              "album": {"images": [{"url": "https://img/1200.jpg", "width": 1200},
                                    {"url": "https://img/640.jpg", "width": 640},
                                    {"url": "https://img/64.jpg", "width": 64}]},
              "external_ids": {"isrc": "QM123"}}}
    """#

    private func client(status: Int, body: String = "", tokens: [String] = ["tok1"]) -> SpotifyAPIClient {
        let remaining = TokenFeed(tokens)
        return SpotifyAPIClient(
            accessToken: { remaining.next() },
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        )
    }

    private final class TokenFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String]
        init(_ tokens: [String]) { self.tokens = tokens }
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            return tokens.count > 1 ? tokens.removeFirst() : tokens[0]
        }
    }

    func testPlayingResponseMapsToTrackAndPosition() async throws {
        let response = try await client(status: 200, body: playingBody).currentlyPlaying()
        let track = response?.track()
        XCTAssertEqual(track?.service, .spotify)
        XCTAssertEqual(track?.title, "Golden Hour")
        XCTAssertEqual(track?.artist, "Ava Lane, Kai")
        XCTAssertEqual(track?.isrc, "QM123")
        XCTAssertEqual(track?.durationMs, 214_980)
        XCTAssertEqual(track?.artworkURL?.absoluteString, "https://img/640.jpg",
                       "closest-to-600px image wins")
        let position = response?.position(capturedAt: 100)
        XCTAssertEqual(position?.positionMs, 42_500)
        XCTAssertEqual(position?.isPlaying, true)
    }

    func test204MeansNothingPlaying() async throws {
        let response = try await client(status: 204).currentlyPlaying()
        XCTAssertNil(response)
    }

    func testItemlessResponseYieldsNilTrack() throws {
        // Ads/podcast edge: is_playing without an item.
        let decoded = try JSONDecoder().decode(
            SpotifyCurrentlyPlayingResponse.self,
            from: Data(#"{"progress_ms": 10, "is_playing": true}"#.utf8))
        XCTAssertNil(decoded.track())
        XCTAssertNil(decoded.position(capturedAt: 0))
    }

    func testHTTPErrorThrows() async {
        do {
            _ = try await client(status: 429).currentlyPlaying()
            XCTFail("429 must throw")
        } catch { /* expected — the next poll tick retries */ }
    }

    func testRepeated401ThrowsUnauthorizedAfterOneRetry() async {
        var callCount = 0
        let counter = { (request: URLRequest) -> (Data, URLResponse) in
            callCount += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401,
                                            httpVersion: nil, headerFields: nil)!)
        }
        let client = SpotifyAPIClient(accessToken: { "tok" }, transport: counter)
        do {
            _ = try await client.currentlyPlaying()
            XCTFail("second 401 must throw")
        } catch {
            XCTAssertEqual(callCount, 2, "exactly one auth retry")
        }
    }
}

// MARK: - Keys

final class SpotifyKeysTests: XCTestCase {

    /// clientID rides the same sanitizer as the GetSongBPM key: unresolved
    /// `$(SPOTIFY_CLIENT_ID)` placeholders and whitespace collapse to "".
    func testPlaceholderAndWhitespaceCollapseToEmpty() {
        let name = "SPOTIFY_CLIENT_ID"
        XCTAssertEqual(TempoProviderKeys.key(named: name, in: [name: "$(SPOTIFY_CLIENT_ID)"]), "")
        XCTAssertEqual(TempoProviderKeys.key(named: name, in: [name: "  \n"]), "")
        XCTAssertEqual(TempoProviderKeys.key(named: name, in: [name: " id-123 "]), "id-123")
    }

    /// An empty resolved clientID must close the auth gate before anything
    /// (Keychain, network, login UI) is touched. Explicit "" injection makes
    /// this deterministic whether or not a local Secrets.xcconfig exists.
    @MainActor
    func testEmptyClientIDKeepsAuthNotConfigured() async {
        let auth = SpotifyAuthService(clientID: TempoProviderKeys.key(named: "SPOTIFY_CLIENT_ID", in: [:]))
        do {
            _ = try await auth.validAccessToken()
            XCTFail("empty clientID must throw .notConfigured")
        } catch SpotifyAuthService.AuthError.notConfigured {
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
    }
}
