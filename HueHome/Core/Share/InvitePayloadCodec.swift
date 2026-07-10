// InvitePayloadCodec.swift
// ChromaGlow — Share Invite (home-join)
//
// Turns the owner's bridge identities into a `lightshade://share?d=…` URL
// (same envelope family as scene sharing — ShareEnvelope's `kind` was designed
// for exactly this) and back. The payload carries ZERO secrets: bridge id,
// last-known host, display name, and the EXPECTED TLS pin. The guest still
// presses the link button and mints their own application key — the QR only
// tells their phone which bridge to trust and where to look first.
//
// Trust rule: the pin in the QR is *verified against*, never ingested. The
// guest performs its own live TOFU capture + /api/0/config cross-check and
// then additionally requires the captured key hash to equal `pinPK`. A
// malicious QR can only cause a refusal — it can never inject trust.
//
// Phase 2 adds a SECOND kind, "invite": a per-guest minted application key
// plus its room/feature grant, time-boxed by `expiresAt`. Unlike home-join
// this payload IS secret-bearing (the token) — it must only ever surface as
// a display-only QR (no ShareLink, never logged; SecretLogScrubTests). The
// pin rule is identical: pinPK is an expectation the guest's own live TOFU
// capture must meet. `clientkey` has no field — a guest key is minted with
// generateclientkey:false and the wire type makes the leak structurally
// impossible. Design: docs/ios/profiles-access-share-invite-design-2026-07.md §3.

import Foundation

// MARK: - Wire types

/// One bridge as it travels in a home-join QR: identity + trust expectation.
struct SharedBridgeJoin: Codable, Equatable {
    /// Canonical uppercase 16-hex Hue bridgeid (the leaf-CN identity).
    var bid: String
    /// Last-known LAN host — a routing hint only; the guest can fall back to
    /// mDNS discovery when DHCP moved the bridge. Never identity.
    var host: String
    var port: Int
    /// Display name from the owner's BridgeRecord.
    var name: String
    /// base64(SHA-256 of the bridge leaf's public key bytes) — matches
    /// BridgePin.publicKeySHA256. The pin the guest verifies its own capture
    /// against.
    var pinPK: String
}

struct HomeJoinPayload: Codable, Equatable {
    var bridges: [SharedBridgeJoin]
    var homeName: String
    var issuedAt: Date
}

/// Envelope mirror of ShareEnvelope for the home-join kind (that struct
/// hard-binds `scene:`; this one binds `join:`). Same `v` space.
private struct HomeJoinEnvelope: Codable {
    var v: Int
    var kind: String
    var join: HomeJoinPayload
}

/// One bridge as it travels in a per-guest invite QR (Phase 2): identity +
/// trust expectation + the guest's OWN minted key and its grant. There is
/// deliberately no clientkey field — the wire type cannot carry one.
struct SharedBridgeInviteGrant: Codable, Equatable {
    /// Canonical uppercase 16-hex Hue bridgeid (the leaf-CN identity).
    var bid: String
    /// Last-known LAN host — routing hint only, never identity.
    var host: String
    var port: Int
    /// Display name from the owner's BridgeRecord.
    var name: String
    /// base64(SHA-256 of the bridge leaf's public key bytes) — verified
    /// against the guest's own live capture, never ingested.
    var pinPK: String
    /// The per-guest application key minted by the owner for THIS bridge.
    /// The one secret in the payload — display-only QR, no ShareLink.
    var token: String
    /// v2 group UUIDs (rooms/zones) on THIS bridge the guest may see.
    /// App-side advisory constraint; enforced by GuestAccessPolicy.
    var allowedGroups: [String]
    /// Granted features: "onOff", "brightness", "scenes".
    var features: [String]
    /// Accept-time gate: the invite QR stops being redeemable after this
    /// (+ clock-skew grace). The KEY does not expire — only the code does.
    var expiresAt: Date
}

struct GuestInvitePayload: Codable, Equatable {
    var bridges: [SharedBridgeInviteGrant]
    var homeName: String
    /// The GuestProfile name this invite was minted for — shown to the
    /// guest ("You're in as 'Alex'") and stored in their access grant.
    var profileName: String
    var issuedAt: Date
}

/// Envelope for the invite kind — binds `invite:`. Same `v` space.
private struct GuestInviteEnvelope: Codable {
    var v: Int
    var kind: String
    var invite: GuestInvitePayload
}

// MARK: - Errors

enum InvitePayloadError: LocalizedError, Equatable {
    case notAShareLink
    case malformedPayload
    case unsupportedVersion(Int)
    case notAnInvite(String)

    var errorDescription: String? {
        switch self {
        case .notAShareLink:
            return "That link isn't a ChromaGlow invite."
        case .malformedPayload:
            return "This invite link is damaged and can't be read."
        case .unsupportedVersion(let v):
            return "This invite was shared from a newer version of ChromaGlow (format \(v)). Update the app to open it."
        case .notAnInvite(let kind):
            return "This link holds a '\(kind)', not a home invite."
        }
    }
}

// MARK: - Codec

enum InvitePayloadCodec {

    static let homeJoinKind = "home-join"
    static let inviteKind   = "invite"

    /// How long a freshly generated token-bearing invite QR stays redeemable.
    static let inviteTTL: TimeInterval = 15 * 60
    /// Clock-skew grace applied at accept time (guest and owner phones may
    /// disagree by a few minutes; the TTL is a photograph bound, not crypto).
    static let acceptSkewGrace: TimeInterval = 5 * 60

    static func encode(_ payload: HomeJoinPayload) throws -> URL {
        let envelope = HomeJoinEnvelope(
            v: ShareEnvelope.currentVersion,
            kind: Self.homeJoinKind,
            join: payload
        )
        let encoder = JSONEncoder()
        // Deterministic like the scene codec: re-sharing the same home
        // produces recognisably the same QR.
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let json = try encoder.encode(envelope)
        let squeezed = try ScenePayloadCodec.compress(json)
        let blob = ScenePayloadCodec.base64URLEncode(squeezed)

        var components = URLComponents()
        components.scheme = ScenePayloadCodec.scheme
        components.host = ScenePayloadCodec.host
        components.queryItems = [URLQueryItem(name: ScenePayloadCodec.queryKey, value: blob)]

        guard let url = components.url else { throw InvitePayloadError.malformedPayload }
        return url
    }

    static func decode(_ url: URL) throws -> HomeJoinPayload {
        guard ScenePayloadCodec.isShareLink(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let blob = components.queryItems?.first(where: { $0.name == ScenePayloadCodec.queryKey })?.value,
              !blob.isEmpty
        else { throw InvitePayloadError.notAShareLink }

        guard let squeezed = ScenePayloadCodec.base64URLDecode(blob),
              let json = try? ScenePayloadCodec.decompress(squeezed)
        else { throw InvitePayloadError.malformedPayload }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Version/kind before body — refuse rather than misdecode (the same
        // discipline as the scene codec).
        guard let probe = try? decoder.decode(KindProbe.self, from: json) else {
            throw InvitePayloadError.malformedPayload
        }
        guard probe.v == ShareEnvelope.currentVersion else {
            throw InvitePayloadError.unsupportedVersion(probe.v)
        }
        guard probe.kind == Self.homeJoinKind else {
            throw InvitePayloadError.notAnInvite(probe.kind)
        }
        guard let envelope = try? decoder.decode(HomeJoinEnvelope.self, from: json),
              !envelope.join.bridges.isEmpty
        else { throw InvitePayloadError.malformedPayload }

        return envelope.join
    }

    // ── Phase 2: per-guest invite (token-bearing) ─────────

    static func encodeInvite(_ payload: GuestInvitePayload) throws -> URL {
        let envelope = GuestInviteEnvelope(
            v: ShareEnvelope.currentVersion,
            kind: Self.inviteKind,
            invite: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let json = try encoder.encode(envelope)
        let squeezed = try ScenePayloadCodec.compress(json)
        let blob = ScenePayloadCodec.base64URLEncode(squeezed)

        var components = URLComponents()
        components.scheme = ScenePayloadCodec.scheme
        components.host = ScenePayloadCodec.host
        components.queryItems = [URLQueryItem(name: ScenePayloadCodec.queryKey, value: blob)]

        guard let url = components.url else { throw InvitePayloadError.malformedPayload }
        return url
    }

    static func decodeInvite(_ url: URL) throws -> GuestInvitePayload {
        guard ScenePayloadCodec.isShareLink(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let blob = components.queryItems?.first(where: { $0.name == ScenePayloadCodec.queryKey })?.value,
              !blob.isEmpty
        else { throw InvitePayloadError.notAShareLink }

        guard let squeezed = ScenePayloadCodec.base64URLDecode(blob),
              let json = try? ScenePayloadCodec.decompress(squeezed)
        else { throw InvitePayloadError.malformedPayload }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let probe = try? decoder.decode(KindProbe.self, from: json) else {
            throw InvitePayloadError.malformedPayload
        }
        guard probe.v == ShareEnvelope.currentVersion else {
            throw InvitePayloadError.unsupportedVersion(probe.v)
        }
        guard probe.kind == Self.inviteKind else {
            throw InvitePayloadError.notAnInvite(probe.kind)
        }
        // A tokenless grant is not an invite — refuse rather than let an
        // accept flow proceed to a guaranteed 401.
        guard let envelope = try? decoder.decode(GuestInviteEnvelope.self, from: json),
              !envelope.invite.bridges.isEmpty,
              envelope.invite.bridges.allSatisfy({ !$0.token.isEmpty })
        else { throw InvitePayloadError.malformedPayload }

        return envelope.invite
    }

    private struct KindProbe: Decodable {
        let v: Int
        let kind: String
    }
}

// MARK: - Expiry (pure, testable)

extension SharedBridgeInviteGrant {
    /// Accept-time gate for ONE bridge's grant. Expired iff `now` is past
    /// `expiresAt` plus the skew grace — a guest phone a few minutes fast
    /// must not see a just-generated code refuse.
    func isExpired(now: Date = Date()) -> Bool {
        now > expiresAt.addingTimeInterval(InvitePayloadCodec.acceptSkewGrace)
    }
}

extension GuestInvitePayload {
    /// The whole invite is expired only when EVERY bridge grant is — the
    /// accept flow still checks per bridge, this drives the top-level
    /// "ask for a fresh code" state.
    func isExpired(now: Date = Date()) -> Bool {
        bridges.allSatisfy { $0.isExpired(now: now) }
    }
}

// MARK: - Kind probe (shared routing)

extension ScenePayloadCodec {
    /// Cheap kind probe so `onOpenURL` routing and scanners can decide which
    /// flow a share link belongs to WITHOUT decoding the full body. The
    /// payloads are a few hundred bytes — one inflate is negligible.
    static func probeKind(_ url: URL) throws -> (v: Int, kind: String) {
        guard isShareLink(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let blob = components.queryItems?.first(where: { $0.name == queryKey })?.value,
              !blob.isEmpty
        else { throw ScenePayloadError.notAShareLink }

        guard let squeezed = base64URLDecode(blob),
              let json = try? decompress(squeezed),
              let probe = try? JSONDecoder().decode(SharedKindProbe.self, from: json)
        else { throw ScenePayloadError.malformedPayload }

        return (probe.v, probe.kind)
    }

    private struct SharedKindProbe: Decodable {
        let v: Int
        let kind: String
    }
}
