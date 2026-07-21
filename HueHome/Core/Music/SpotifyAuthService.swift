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

// MARK: - Config (paste at Gate D)

enum SpotifyKeys {
    /// From Brian's dashboard app at developer.spotify.com. Empty = the
    /// Spotify source stays inert even with the DEBUG flag on.
    static let clientID = ""
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

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, challenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyKeys.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
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

    enum AuthError: Error { case notConfigured, loginCancelled, exchangeFailed }

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
    func validAccessToken() async throws -> String {
        guard !clientID.isEmpty else { throw AuthError.notConfigured }
        let expiry = defaults.double(forKey: Self.expiryDefaultsKey)
        if Date().timeIntervalSince1970 < expiry - 60,
           let token = try? KeychainManager.shared.load(for: Self.accessTokenAccount) {
            return token
        }
        if let refresh = try? KeychainManager.shared.load(for: Self.refreshTokenAccount) {
            return try await exchange(form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": clientID,
            ])
        }
        return try await interactiveLogin()
    }

    func unlink() {
        try? KeychainManager.shared.delete(for: Self.accessTokenAccount)
        try? KeychainManager.shared.delete(for: Self.refreshTokenAccount)
        defaults.removeObject(forKey: Self.expiryDefaultsKey)
    }

    // MARK: Interactive login (untestable edge, kept minimal)

    private func interactiveLogin() async throws -> String {
        let verifier = SpotifyPKCE.codeVerifier()
        let url = SpotifyPKCE.authorizeURL(
            clientID: clientID,
            challenge: SpotifyPKCE.codeChallenge(for: verifier)
        )
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "chromaglow"
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? AuthError.loginCancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.exchangeFailed }

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

        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        else {
            throw AuthError.exchangeFailed
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
