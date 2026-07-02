// BridgeTrustEvaluator.swift
// ChromaGlow — Bridge TLS trust (audit H-01/H-02/M-01/H-06, Decision D-016)
//
// Core trust evaluation for every Hue bridge TLS connection. Replaces the
// former trust-all delegates. The identity model mirrors the accepted Android
// contract (D-001/D-002/D-014):
//
//  - Canonical bridge identity is the uppercase 16-hex `bridgeid`, carried in
//    the leaf certificate CN and cross-checked against /api/0/config at
//    pairing time.
//  - At pairing (user-initiated, link button pressed) the leaf is captured and
//    pinned (TOFU): public-key SHA-256 + cert SHA-256 + the DER itself.
//  - Every later connection must pass a REAL SecTrustEvaluateWithError chain
//    evaluation (anchors-only: bundled Hue roots + the pinned leaf) AND match
//    the pinned bridgeid-CN AND the pinned public key. A key change is
//    accepted only when the chain validates against the bundled Signify roots
//    alone (CA-attested cert rotation — exactly Android's CA+CN contract).
//
// `.useCredential` is structurally impossible without a successful evaluation.

import Foundation
import Security
import CryptoKit

// MARK: - BridgePin

/// The pinned TLS identity of one paired bridge. Not a secret — the public
/// key/cert of a device that broadcasts them on the LAN — but authoritative
/// for identity, so the Keychain copy is the source of truth.
struct BridgePin: Codable, Equatable {
    /// Canonical uppercase 16-hex Hue bridgeid (leaf CN, config-verified).
    let bridgeID: String
    /// Base64 SHA-256 over SecKeyCopyExternalRepresentation of the leaf key.
    let publicKeySHA256: String
    /// Base64 SHA-256 over the full leaf DER (diagnostics / continuity checks).
    let certSHA256: String
    /// Full leaf DER — needed as a trust anchor for self-signed bridges.
    let certDER: Data
    /// Last-known LAN host. Routing metadata only — never identity.
    var host: String
    let pinnedAt: Date
}

// MARK: - PairingLeafCapture

/// The leaf identity observed during a pairing/TOFU handshake.
struct PairingLeafCapture: Equatable {
    let bridgeID: String        // canonical uppercase 16-hex from the leaf CN
    let publicKeySHA256: String
    let certSHA256: String
    let certDER: Data
    /// True when the chain validated against the bundled Hue roots alone
    /// (CA-signed bridge). False for legacy self-signed leaves.
    let caValidated: Bool

    func pin(host: String) -> BridgePin {
        BridgePin(
            bridgeID: bridgeID,
            publicKeySHA256: publicKeySHA256,
            certSHA256: certSHA256,
            certDER: certDER,
            host: host,
            pinnedAt: Date()
        )
    }
}

// MARK: - Verdicts

enum BridgeTrustRejection: String, Equatable {
    case noLeafCertificate      = "no-leaf"
    case commonNameNotABridgeID = "cn-not-bridgeid"
    case noPinForBridgeID       = "no-pin"
    case pinMismatch            = "pin-mismatch"
    case chainEvaluationFailed  = "chain-eval-failed"
}

enum BridgeTrustVerdict: Equatable {
    case acceptedPinned(bridgeID: String)
    /// Leaf key differs from the pin, but the chain validates against the
    /// bundled Signify roots and the CN equals the pinned bridgeid — a
    /// CA-attested cert rotation. Caller should persist `newPin`.
    case acceptedCAValidatedRotation(bridgeID: String, newPin: BridgePin)
    case rejected(BridgeTrustRejection)
}

// MARK: - BridgeTrust

enum BridgeTrust {

    // ── Leaf / identity helpers ──────────────────────────────

    static func leafCertificate(in trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    static func commonName(of certificate: SecCertificate) -> String? {
        var cn: CFString?
        guard SecCertificateCopyCommonName(certificate, &cn) == errSecSuccess else { return nil }
        return cn as String?
    }

    /// Strict Android-parity contract: exactly 16 hex chars, normalized uppercase.
    static func canonicalBridgeID(from raw: String) -> String? {
        guard raw.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil else { return nil }
        return raw.uppercased()
    }

    static func publicKeySHA256(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Data(SHA256.hash(data: keyData)).base64EncodedString()
    }

    static func certSHA256(of certificate: SecCertificate) -> String {
        Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)).base64EncodedString()
    }

    // ── Chain evaluation ─────────────────────────────────────

    /// Real chain evaluation against an explicit anchor set (no system roots).
    /// Basic X.509 policy, NOT the SSL server policy: Apple's SSL policy
    /// requires a SubjectAltName, and Hue bridge leaves are CN-only (no SAN),
    /// so the SSL policy would reject every real bridge. Chain integrity +
    /// validity period come from this evaluation; the server-identity binding
    /// comes from the bridgeid-CN + pin checks — the same split as Android's
    /// HueRootTrustManager + HueLeafHostnameVerifier.
    static func evaluateChain(_ trust: SecTrust, anchors: [SecCertificate]) -> Bool {
        guard !anchors.isEmpty else { return false }
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    // ── Data-plane verdict ───────────────────────────────────

    static func verdict(
        trust: SecTrust,
        pins: [BridgePin],
        roots: [SecCertificate] = HueBridgeTrustRoots.all
    ) -> BridgeTrustVerdict {
        guard let leaf = leafCertificate(in: trust) else {
            return .rejected(.noLeafCertificate)
        }
        guard let cn = commonName(of: leaf),
              let bridgeID = canonicalBridgeID(from: cn) else {
            return .rejected(.commonNameNotABridgeID)
        }
        guard let pin = pins.first(where: { $0.bridgeID == bridgeID }) else {
            return .rejected(.noPinForBridgeID)
        }
        guard let presentedKeyHash = publicKeySHA256(of: leaf) else {
            return .rejected(.noLeafCertificate)
        }

        if presentedKeyHash == pin.publicKeySHA256 {
            // Pinned key. The chain evaluation must still succeed — validity
            // period, signature integrity, SSL policy — anchored to the
            // presented leaf (self-signed bridges) plus the bundled roots.
            guard evaluateChain(trust, anchors: roots + [leaf]) else {
                return .rejected(.chainEvaluationFailed)
            }
            return .acceptedPinned(bridgeID: bridgeID)
        }

        // Key differs from the pin: accept ONLY a CA-attested rotation — the
        // chain must validate against the bundled Hue roots ALONE and the CN
        // must still equal the pinned bridgeid.
        guard evaluateChain(trust, anchors: roots) else {
            return .rejected(.pinMismatch)
        }
        let rotated = BridgePin(
            bridgeID: bridgeID,
            publicKeySHA256: presentedKeyHash,
            certSHA256: certSHA256(of: leaf),
            certDER: SecCertificateCopyData(leaf) as Data,
            host: pin.host,
            pinnedAt: Date()
        )
        return .acceptedCAValidatedRotation(bridgeID: bridgeID, newPin: rotated)
    }

    // ── Pairing / TOFU capture ───────────────────────────────

    /// Trust decision for the user-initiated pairing window (and the one-time
    /// upgrade migration): the leaf CN must be a well-formed bridgeid AND the
    /// chain must evaluate successfully against the bundled roots plus the
    /// presented leaf itself (legacy self-signed bridges). Returns nil —
    /// reject — otherwise.
    static func pairingCapture(
        trust: SecTrust,
        roots: [SecCertificate] = HueBridgeTrustRoots.all
    ) -> PairingLeafCapture? {
        guard let leaf = leafCertificate(in: trust),
              let cn = commonName(of: leaf),
              let bridgeID = canonicalBridgeID(from: cn),
              let keyHash = publicKeySHA256(of: leaf) else { return nil }
        // Order matters: the roots-only pass classifies CA-signed leaves, the
        // roots+leaf pass is the actual accept gate for self-signed leaves.
        let caValidated = evaluateChain(trust, anchors: roots)
        guard caValidated || evaluateChain(trust, anchors: roots + [leaf]) else { return nil }
        return PairingLeafCapture(
            bridgeID: bridgeID,
            publicKeySHA256: keyHash,
            certSHA256: certSHA256(of: leaf),
            certDER: SecCertificateCopyData(leaf) as Data,
            caValidated: caValidated
        )
    }
}
