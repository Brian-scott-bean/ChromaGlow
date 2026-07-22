// SpotifyAuthService.swift
// ChromaGlow — Core/Music (music integration R5, DEV-FLAGGED)
//
// Authorization Code + PKCE against accounts.spotify.com — the sanctioned
// mobile flow (no client secret ever exists on device). Reality check
// (design doc §2.3): until ChromaGlow qualifies for Spotify's extended
// quota (registered business, 250k MAU), this works ONLY for accounts
// allowlisted in Brian's dashboard — hence FeatureFlags.spotifySource.
//
// Tokens live in KeychainManager (service com.lightshade.app) under
// spotify_access_token / spotify_refresh_token; expiry (not a secret) in
// UserDefaults. NOTHING here logs URLs, headers, or bodies (H-03).

import Foundation
import CryptoKit
import AuthenticationServices

// MARK: - Config

enum SpotifyKeys {
    /// From Brian's dashboard app at developer.spotify.com, pasted into the
    /// git-ignored Config/Secrets.xcconfig (SPOTIFY_CLIENT_ID) — same flow
    /// as the GetSongBPM key, same sanitizer. Empty = the Spotify source
    /// stays inert even with the DEBUG flag on.
    static var clientID: String {
        TempoProviderKeys.key(named: "SPOTIFY_CLIENT_ID", in: Bundle.main.infoDictionary)
    }
    /// Must be registered VERBATIM in the dashboard's Redirect URIs.
    static let redirectURI = "chromaglow://spotify-callback"
    static let scopes = "user-read-playback-state user-read-currently-playing user-modify-playback-state"
}

// MARK: - Pure PKCE + URL seams (tested)

enum SpotifyPKCE {
    /// RFC 7636 §4.1: 43–128 chars of [A-Za-z0-9\-._~]. 64 random octets
    /// base64url-encoded = 86 chars.
    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256: base64url(SHA256(ascii(verifier))) — RFC 7636 §4.2.
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// OAuth `state` (CSRF/mix-up defense): 16 random octets base64url.
    static func stateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyKeys.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: SpotifyKeys.scopes),
        ]
        return components.url!
    }
}

struct SpotifyTokenResponse: Decodable, Equatable {
    var access_token: String
    var refresh_token: String?
    var expires_in: TimeInterval
}

// MARK: - Auth service

@MainActor
final class SpotifyAuthService: NSObject {

    static let accessTokenAccount = "spotify_access_token"
    static let refreshTokenAccount = "spotify_refresh_token"
    static let expiryDefaultsKey = "music.spotify.tokenExpiry"

    /// exchangeRejected = the token endpoint said NO (4xx/decode) — the
    /// stored grant is definitively dead. Transport trouble is NOT mapped
    /// here; it propagates as the transport's own error so callers never
    /// wipe tokens over a network blip. notLinked = no refresh token and
    /// interactive login wasn't allowed in this context (background poll).
    enum AuthError: Error { case notConfigured, loginCancelled, exchangeRejected, notLinked }

    private let clientID: String
    private let transport: TempoTransport
    private let defaults: UserDefaults

    init(
        clientID: String = SpotifyKeys.clientID,
        defaults: UserDefaults = .standard,
        transport: @escaping TempoTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.clientID = clientID
        self.defaults = defaults
        self.transport = transport
    }

    var isLinked: Bool {
        (try? KeychainManager.shared.load(for: Self.refreshTokenAccount)) != nil
    }

    /// A currently-valid access token: cached → refreshed → interactive
    /// login (ASWebAuthenticationSession) as the last resort.
    ///
    /// `forceRefresh` skips the cached token — the API client passes it on
    /// its one 401 retry (the local expiry clock said "valid" but Spotify
    /// disagreed; re-serving the same token guaranteed a second 401).
    /// `allowInteractive` gates the login sheet to explicit user contexts
    /// (the picker's start()) — a background poll must never pop it.
    func validAccessToken(forceRefresh: Bool = false,
                          allowInteractive: Bool = false) async throws -> String {
        guard !clientID.isEmpty else { throw AuthError.notConfigured }
        if !forceRefresh {
            let expiry = defaults.double(forKey: Self.expiryDefaultsKey)
            if Date().timeIntervalSince1970 < expiry - 60,
               let token = try? KeychainManager.shared.load(for: Self.accessTokenAccount) {
                return token
            }
        }
        if let refresh = try? KeychainManager.shared.load(for: Self.refreshTokenAccount) {
            // Single-flight, static because auth instances are per-source:
            // Spotify rotates refresh tokens, so two concurrent refreshes
            // (a dying poll's 401 retry + a fresh start()) both spending the
            // SAME token meant the loser got exchangeRejected — and start()'s
            // rejected arm then unlinked the freshly-rotated healthy grant.
            if let inflight = Self.inflightRefresh {
                return try await inflight.value
            }
            let task = Task<String, Error> {
                try await exchange(form: [
                    "grant_type": "refresh_token",
                    "refresh_token": refresh,
                    "client_id": clientID,
                ])
            }
            Self.inflightRefresh = task
            defer { Self.inflightRefresh = nil }
            return try await task.value
        }
        guard allowInteractive else { throw AuthError.notLinked }
        return try await interactiveLogin()
    }

    /// The one in-flight refresh exchange, joined by every concurrent caller.
    private static var inflightRefresh: Task<String, Error>?

    func unlink() {
        try? KeychainManager.shared.delete(for: Self.accessTokenAccount)
        try? KeychainManager.shared.delete(for: Self.refreshTokenAccount)
        defaults.removeObject(forKey: Self.expiryDefaultsKey)
    }

    // MARK: Interactive login (untestable edge, kept minimal)

    /// Held for the sheet's lifetime — a session with no strong reference
    /// can deallocate mid-presentation (vanishing sheet, completion that
    /// never fires).
    private var activeWebAuthSession: ASWebAuthenticationSession?

    private func interactiveLogin() async throws -> String {
        let verifier = SpotifyPKCE.codeVerifier()
        let expectedState = SpotifyPKCE.stateToken()
        let url = SpotifyPKCE.authorizeURL(
            clientID: clientID,
            challenge: SpotifyPKCE.codeChallenge(for: verifier),
            state: expectedState
        )
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "chromaglow"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in self?.activeWebAuthSession = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? AuthError.loginCancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeWebAuthSession = session
            if !session.start() {
                // Couldn't present (no window scene yet) — the completion
                // handler never fires in this case, so fail here instead
                // of leaving the caller suspended forever.
                activeWebAuthSession = nil
                continuation.resume(throwing: AuthError.loginCancelled)
            }
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        if let denial = items?.first(where: { $0.name == "error" })?.value {
            throw denial == "access_denied" ? AuthError.loginCancelled
                                            : AuthError.exchangeRejected
        }
        guard items?.first(where: { $0.name == "state" })?.value == expectedState else {
            throw AuthError.exchangeRejected   // CSRF/mix-up — refuse the code
        }
        guard let code = items?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.exchangeRejected }

        return try await exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyKeys.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    private func exchange(form: [String: String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        // Transport errors propagate as thrown (never mapped to
        // exchangeRejected) — a network blip must not read as a dead grant.
        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        else {
            throw AuthError.exchangeRejected
        }
        try? KeychainManager.shared.save(value: decoded.access_token, for: Self.accessTokenAccount)
        if let refresh = decoded.refresh_token {
            try? KeychainManager.shared.save(value: refresh, for: Self.refreshTokenAccount)
        }
        defaults.set(Date().timeIntervalSince1970 + decoded.expires_in,
                     forKey: Self.expiryDefaultsKey)
        return decoded.access_token
    }
}

extension SpotifyAuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
