// ScenePayloadCodec.swift
// ChromaGlow — scene sharing
//
// Turns a Composer preset into a `lightshade://share?d=…` URL and back. The
// URL *is* the scene: there is no server, no upload, no account. Whoever can
// read the link (or scan the QR that encodes it) can reconstruct the scene
// offline. That keeps sharing inside the local-first rule the rest of the app
// obeys.
//
// Wire format:
//   lightshade://share?d=<base64url( zlib( JSON(ShareEnvelope) ) )>
//
// The envelope is versioned. A decoder that meets a version it does not know
// says so instead of guessing, so a future v2 producer can add fields without
// this build silently reconstructing a wrong scene.
//
// What travels: the scene's *design* — name, look, and the four layers. What
// does not: identity and provenance (`id`, `createdAt`, `isBuiltIn`,
// `aiPrompt`, `providerModel`). A shared scene arrives as a new creation of
// the receiver's, not as a claim on the sender's library.

import Foundation

// MARK: - Wire types

/// The scene as it travels: design only, no identity, no provenance.
struct SharedScene: Codable, Equatable {
    var name: String
    var icon: String
    var accentColorHex: String
    var category: PresetCategory
    var seasonMonths: [Int]?

    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig

    var preferredTransport: CompositionPreferredTransport?
    /// A sequence is part of the artistry, so it travels. It is also the one
    /// field big enough to push a payload past QR capacity — when that happens
    /// `SceneQRRenderer` reports it rather than quietly dropping the sequence.
    var sequence: CompositionSequence?

    init(preset: CompositionPreset) {
        name = preset.name
        icon = preset.icon
        accentColorHex = preset.accentColorHex
        category = preset.category
        seasonMonths = preset.seasonMonths
        palette = preset.palette
        motion = preset.motion
        envelope = preset.envelope
        reaction = preset.reaction
        preferredTransport = preset.preferredTransport
        sequence = preset.sequence
    }

    /// Rebuild as a preset the receiver owns: fresh identity, fresh timestamps,
    /// never built-in. A shared "Ocean Drift" does not overwrite the recipient's
    /// built-in "Ocean Drift".
    func makePreset(id: UUID = UUID(), now: Date = Date()) -> CompositionPreset {
        CompositionPreset(
            id: id,
            name: name,
            icon: icon,
            accentColorHex: accentColorHex,
            isBuiltIn: false,
            category: category == .myCreations ? .myCreations : category,
            seasonMonths: seasonMonths,
            palette: palette,
            motion: motion,
            envelope: envelope,
            reaction: reaction,
            createdAt: now,
            updatedAt: now,
            aiPrompt: nil,
            providerModel: nil,
            preferredTransport: preferredTransport,
            sequence: sequence
        )
    }
}

/// Versioned outer envelope. `kind` leaves room for sharing things that are not
/// compositions (a bridge scene, a palette) without minting a second URL host.
struct ShareEnvelope: Codable, Equatable {
    static let currentVersion = 1
    static let compositionKind = "composition"

    var v: Int
    var kind: String
    var scene: SharedScene
}

// MARK: - Errors

enum ScenePayloadError: LocalizedError, Equatable {
    case notAShareLink
    case malformedPayload
    case unsupportedVersion(Int)
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .notAShareLink:
            return "That link isn't a ChromaGlow scene."
        case .malformedPayload:
            return "This scene link is damaged and can't be read."
        case .unsupportedVersion(let v):
            return "This scene was shared from a newer version of ChromaGlow (format \(v)). Update the app to open it."
        case .unsupportedKind(let kind):
            return "This link holds a '\(kind)', which this version of ChromaGlow can't open."
        }
    }
}

// MARK: - Codec

enum ScenePayloadCodec {

    static let scheme = "lightshade"
    static let host = "share"
    static let queryKey = "d"

    // MARK: Encode

    static func encode(_ preset: CompositionPreset) throws -> URL {
        try encode(SharedScene(preset: preset))
    }

    static func encode(_ scene: SharedScene) throws -> URL {
        let envelope = ShareEnvelope(
            v: ShareEnvelope.currentVersion,
            kind: ShareEnvelope.compositionKind,
            scene: scene
        )

        let encoder = JSONEncoder()
        // Deterministic: the same scene must always produce the same link, so a
        // re-share is recognisably the same QR rather than a fresh-looking one.
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let json = try encoder.encode(envelope)
        let squeezed = try compress(json)
        let blob = base64URLEncode(squeezed)

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: queryKey, value: blob)]

        guard let url = components.url else { throw ScenePayloadError.malformedPayload }
        return url
    }

    // MARK: Decode

    static func decode(_ url: URL) throws -> SharedScene {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host
        else { throw ScenePayloadError.notAShareLink }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let blob = components.queryItems?.first(where: { $0.name == queryKey })?.value,
              !blob.isEmpty
        else { throw ScenePayloadError.notAShareLink }

        guard let squeezed = base64URLDecode(blob) else { throw ScenePayloadError.malformedPayload }

        let json: Data
        do { json = try decompress(squeezed) }
        catch { throw ScenePayloadError.malformedPayload }

        // Read the version before trusting the body: an envelope from the future
        // may well decode into a plausible-but-wrong scene otherwise.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let probe = try? decoder.decode(VersionProbe.self, from: json) else {
            throw ScenePayloadError.malformedPayload
        }
        guard probe.v == ShareEnvelope.currentVersion else {
            throw ScenePayloadError.unsupportedVersion(probe.v)
        }
        guard probe.kind == ShareEnvelope.compositionKind else {
            throw ScenePayloadError.unsupportedKind(probe.kind)
        }

        guard let envelope = try? decoder.decode(ShareEnvelope.self, from: json) else {
            throw ScenePayloadError.malformedPayload
        }
        return envelope.scene
    }

    /// Cheap "is this ours?" test for `onOpenURL`, which also sees widget links.
    static func isShareLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    private struct VersionProbe: Decodable {
        let v: Int
        let kind: String
    }

    // MARK: - zlib

    // Compression matters here: a preset's JSON is mostly repeated key names and
    // float digits, which deflate shrinks by roughly 3-4x. That is the
    // difference between a QR a phone reads instantly and one it struggles with.

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw ScenePayloadError.malformedPayload }
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw ScenePayloadError.malformedPayload }
        return try (data as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: - base64url (RFC 4648 §5)

    // Plain base64 uses `+`, `/` and `=`, all of which need percent-escaping in a
    // query string. Escaping would inflate the payload and, worse, make the QR's
    // character set larger. base64url avoids all three.

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore the stripped padding to a multiple of 4.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
