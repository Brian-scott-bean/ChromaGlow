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

    private struct KindProbe: Decodable {
        let v: Int
        let kind: String
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
