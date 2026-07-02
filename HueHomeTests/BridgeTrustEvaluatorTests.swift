// BridgeTrustEvaluatorTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit H-01/H-02/M-01/H-06 (trust-all TLS → pinned
// evaluator, D-016):
//  - The delegate NEVER returns .useCredential without a successful chain
//    evaluation + bridgeid-CN + pin match (guards against reintroducing the
//    evaluate-then-discard pattern).
//  - A mismatched-CN leaf and a same-CN/different-key impersonator are
//    rejected; only a CA-validated chain may rotate a pinned key.
//  - The bundled Hue root bytes match the human-verified SHA-256 fingerprints.
//
// Fixtures are deterministic openssl-generated EC P-256 certificates embedded
// as DER base64 (no bundle-resource wiring). "Bridge 1" simulates a legacy
// self-signed bridge whose CN is the (lowercase) bridgeid 001788fffe23a688;
// the "attacker" key is a different keypair; "Test Hue Root" is a test CA
// standing in for the Signify roots in rotation tests.

import XCTest
import Security
import CryptoKit
@testable import HueHome

final class BridgeTrustEvaluatorTests: XCTestCase {

    // MARK: - Fixtures (DER, base64)

    /// Self-signed, CN=001788fffe23a688 (lowercase — exercises normalization), key A.
    private static let leafValidB64 = "MIIB8jCCAZmgAwIBAgIUFW7x88dzOByc1OInCKUcvLRuvQ4wCgYIKoZIzj0EAwIwPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhmZmZlMjNhNjg4MB4XDTI2MDcwMjA1MjkyOFoXDTQ2MDYyNzA1MjkyOFowPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhmZmZlMjNhNjg4MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqICxNdZiacduDMXTJk6fTd2JU7v/03ElqChEOLtz1vluJ+3cai7vPUv05m7suV7mrycI3eKxk2M7oP5y9qZqTKN1MHMwHQYDVR0OBBYEFLm8meNVL6ekj8wImAV5vuVO5BEtMB8GA1UdIwQYMBaAFLm8meNVL6ekj8wImAV5vuVO5BEtMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0cAMEQCIAdXuwuuUghEkpGFOF4fVEMwh1YSX/O/JckTqjPGIwYgAiAnA+uR9k9b0XYLcfZ4EMJCzSstu55l+qEIp0B540dnxg=="

    /// Self-signed, CN=001788FFFE23A688, key B (impersonator: right CN, wrong key).
    private static let leafImpersonatorB64 = "MIIB9DCCAZmgAwIBAgIUB6tnj+dYWf0DfyRTg6N385Q01v8wCgYIKoZIzj0EAwIwPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhGRkZFMjNBNjg4MB4XDTI2MDcwMjA1MjkyOFoXDTQ2MDYyNzA1MjkyOFowPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhGRkZFMjNBNjg4MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEppM/6SmPdp/+4heM02wRzZYRUXLkGvvKQ95Wdu5MFMd2TsAIX6heo0zM+MRQPdRurjZiF5suvlA6PEfzVezyh6N1MHMwHQYDVR0OBBYEFJSt4oWC/lsZS8HEkTwv9VyuQvD3MB8GA1UdIwQYMBaAFJSt4oWC/lsZS8HEkTwv9VyuQvD3MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0kAMEYCIQDChEnk5eWd8Czlh9lgswmaHYevv1HKMoFAw4g82Z2sHQIhAPGXjc6n4OxiY+cPyVIExIVLZcAsyDIr4IJC+/7JBrOd"

    /// Self-signed, CN=totally-not-a-bridge (not a bridgeid).
    private static let leafWrongCNB64 = "MIIB7jCCAZOgAwIBAgIUF1qEwUOjpvRh1v/mZZ3KNLIUn1EwCgYIKoZIzj0EAwIwOzELMAkGA1UEBhMCTkwxDTALBgNVBAoMBEV2aWwxHTAbBgNVBAMMFHRvdGFsbHktbm90LWEtYnJpZGdlMB4XDTI2MDcwMjA1MjkyOFoXDTQ2MDYyNzA1MjkyOFowOzELMAkGA1UEBhMCTkwxDTALBgNVBAoMBEV2aWwxHTAbBgNVBAMMFHRvdGFsbHktbm90LWEtYnJpZGdlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEppM/6SmPdp/+4heM02wRzZYRUXLkGvvKQ95Wdu5MFMd2TsAIX6heo0zM+MRQPdRurjZiF5suvlA6PEfzVezyh6N1MHMwHQYDVR0OBBYEFJSt4oWC/lsZS8HEkTwv9VyuQvD3MB8GA1UdIwQYMBaAFJSt4oWC/lsZS8HEkTwv9VyuQvD3MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqGSM49BAMCA0kAMEYCIQCvmYL6K6shObGKYs6JFiPpyx81GSbYzIDqcyhzVNpH/AIhAKJKH1cAhVoquNnpV2aglieyYVrVfj8D4CHwg5edza1v"

    /// Test CA (stand-in for a Signify root in rotation tests).
    private static let testCAB64 = "MIIB2zCCAYGgAwIBAgIUQusp3kqU4A5iSBZRMe21KI7o3PowCgYIKoZIzj0EAwIwOzELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1Rlc3QgSHVlIENBMRYwFAYDVQQDDA1UZXN0IEh1ZSBSb290MB4XDTI2MDcwMjA1MTYzNFoXDTQ2MDYyNzA1MTYzNFowOzELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1Rlc3QgSHVlIENBMRYwFAYDVQQDDA1UZXN0IEh1ZSBSb290MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEE2pZSgSF7rGmCRkLRaadX8b5PwS0SCvhE+qDw6dhscDGsT9EwrzorblDJ4GJIjC2WpJN029cvGUwxSmNna6/caNjMGEwHQYDVR0OBBYEFImieyveD5GU1NjNWqoQpyS52MABMB8GA1UdIwQYMBaAFImieyveD5GU1NjNWqoQpyS52MABMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gAMEUCICS2tLjXzfyREliCIjNIyr8ZzW3mRm67BQGp3CZJfFd1AiEA9bfakIrvI1pozVZtMQQNqI29WEswx7kmd0OA1Ki1sG0="

    /// CA-signed by Test CA, CN=001788FFFE23A688, key A (same key as leaf-valid).
    private static let leafCASignedB64 = "MIIB8TCCAZagAwIBAgIUcwOBUv4G2IfDNcQ0SGPXJE4j3i8wCgYIKoZIzj0EAwIwOzELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1Rlc3QgSHVlIENBMRYwFAYDVQQDDA1UZXN0IEh1ZSBSb290MB4XDTI2MDcwMjA1MjkyOFoXDTQ1MDgzMTA1MjkyOFowPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhGRkZFMjNBNjg4MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqICxNdZiacduDMXTJk6fTd2JU7v/03ElqChEOLtz1vluJ+3cai7vPUv05m7suV7mrycI3eKxk2M7oP5y9qZqTKN1MHMwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFLm8meNVL6ekj8wImAV5vuVO5BEtMB8GA1UdIwQYMBaAFImieyveD5GU1NjNWqoQpyS52MABMAoGCCqGSM49BAMCA0kAMEYCIQDztGAHP8Vm1H+y6RGkw5BPXsvAgQduvDQInkAvULoWjAIhALW/SBZn0MOIdt03PDRrDpYd7NW9w4IwrJ9UN45OxonT"

    /// CA-signed by Test CA, CN=001788FFFE23A688, key B (legitimate rotation).
    private static let leafCARotatedB64 = "MIIB8DCCAZagAwIBAgIUcwOBUv4G2IfDNcQ0SGPXJE4j3jAwCgYIKoZIzj0EAwIwOzELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1Rlc3QgSHVlIENBMRYwFAYDVQQDDA1UZXN0IEh1ZSBSb290MB4XDTI2MDcwMjA1MjkyOFoXDTQ1MDgzMTA1MjkyOFowPjELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRkwFwYDVQQDDBAwMDE3ODhGRkZFMjNBNjg4MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEppM/6SmPdp/+4heM02wRzZYRUXLkGvvKQ95Wdu5MFMd2TsAIX6heo0zM+MRQPdRurjZiF5suvlA6PEfzVezyh6N1MHMwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFJSt4oWC/lsZS8HEkTwv9VyuQvD3MB8GA1UdIwQYMBaAFImieyveD5GU1NjNWqoQpyS52MABMAoGCCqGSM49BAMCA0gAMEUCIG4XKIgeXxCtGvYcYdQDO2j8FrF40DbMyeYKVnrDDZ7CAiEAjA3nwHW74APZo412+CFIgy7arhvu+qAfoK6V8gfzy9Q="

    private static let bridgeID = "001788FFFE23A688"

    // MARK: - Helpers

    private func certificate(_ base64: String) -> SecCertificate {
        let der = Data(base64Encoded: base64)!
        return SecCertificateCreateWithData(nil, der as CFData)!
    }

    private func makeTrust(_ chain: [SecCertificate]) -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, nil), &trust)
        XCTAssertEqual(status, errSecSuccess)
        return trust!
    }

    private func pin(for cert: SecCertificate, bridgeID: String = BridgeTrustEvaluatorTests.bridgeID) -> BridgePin {
        BridgePin(
            bridgeID: bridgeID,
            publicKeySHA256: BridgeTrust.publicKeySHA256(of: cert)!,
            certSHA256: BridgeTrust.certSHA256(of: cert),
            certDER: SecCertificateCopyData(cert) as Data,
            host: "192.0.2.10",
            pinnedAt: Date()
        )
    }

    // MARK: - Bundled roots

    func testBundledRootsMatchHumanVerifiedFingerprints() {
        let roots = HueBridgeTrustRoots.all
        XCTAssertEqual(roots.count, 2, "both Hue roots must decode from the embedded DER")
        let fingerprints = Set(roots.map { cert -> String in
            let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            return digest.map { String(format: "%02X", $0) }.joined()
        })
        XCTAssertEqual(fingerprints, HueBridgeTrustRoots.expectedSHA256Fingerprints)
    }

    // MARK: - Data-plane verdict

    func testPinnedSelfSignedLeafIsAccepted() {
        let leaf = certificate(Self.leafValidB64)
        let verdict = BridgeTrust.verdict(trust: makeTrust([leaf]), pins: [pin(for: leaf)])
        XCTAssertEqual(verdict, .acceptedPinned(bridgeID: Self.bridgeID),
                       "lowercase CN must normalize to the canonical uppercase bridgeid")
    }

    func testUnpinnedLeafIsRejected() {
        let leaf = certificate(Self.leafValidB64)
        let verdict = BridgeTrust.verdict(trust: makeTrust([leaf]), pins: [])
        XCTAssertEqual(verdict, .rejected(.noPinForBridgeID),
                       "no pin → fail closed; trust-all must never return")
    }

    func testSameCNDifferentKeyImpersonatorIsRejected() {
        let real = certificate(Self.leafValidB64)
        let attacker = certificate(Self.leafImpersonatorB64)
        let verdict = BridgeTrust.verdict(trust: makeTrust([attacker]), pins: [pin(for: real)])
        XCTAssertEqual(verdict, .rejected(.pinMismatch),
                       "a self-signed leaf with the right CN but the wrong key is the MITM case")
    }

    func testNonBridgeIDCommonNameIsRejected() {
        let real = certificate(Self.leafValidB64)
        let evil = certificate(Self.leafWrongCNB64)
        let verdict = BridgeTrust.verdict(trust: makeTrust([evil]), pins: [pin(for: real)])
        XCTAssertEqual(verdict, .rejected(.commonNameNotABridgeID))
    }

    func testCAValidatedRotationIsAcceptedOnlyWithTrustedRoot() {
        let real = certificate(Self.leafValidB64)
        let rotated = certificate(Self.leafCARotatedB64)
        let testCA = certificate(Self.testCAB64)
        let pins = [pin(for: real)]

        // With the issuing CA in the anchor set: legitimate rotation.
        let accepted = BridgeTrust.verdict(
            trust: makeTrust([rotated, testCA]), pins: pins, roots: [testCA]
        )
        guard case .acceptedCAValidatedRotation(let bridgeID, let newPin) = accepted else {
            return XCTFail("expected CA-validated rotation, got \(accepted)")
        }
        XCTAssertEqual(bridgeID, Self.bridgeID)
        XCTAssertEqual(newPin.publicKeySHA256, BridgeTrust.publicKeySHA256(of: rotated))

        // Against the REAL bundled Hue roots the same chain must be rejected:
        // an unattested key change never rotates a pin.
        let rejected = BridgeTrust.verdict(trust: makeTrust([rotated, testCA]), pins: pins)
        XCTAssertEqual(rejected, .rejected(.pinMismatch))
    }

    // MARK: - Delegate (never .useCredential without acceptance)

    func testDelegateCancelsWithoutServerTrust() {
        let delegate = BridgePinnedTrustDelegate(pinProvider: { [] })
        let (disposition, credential) = delegate.disposition(for: nil)
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testDelegateCancelsForUnpinnedLeaf() {
        let leaf = certificate(Self.leafValidB64)
        let delegate = BridgePinnedTrustDelegate(pinProvider: { [] })
        let (disposition, credential) = delegate.disposition(for: makeTrust([leaf]))
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential, "no credential may accompany a rejection")
    }

    func testDelegateCancelsForImpersonator() {
        let real = certificate(Self.leafValidB64)
        let attacker = certificate(Self.leafImpersonatorB64)
        let delegate = BridgePinnedTrustDelegate(pinProvider: { [self.pin(for: real)] })
        let (disposition, credential) = delegate.disposition(for: makeTrust([attacker]))
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
    }

    func testDelegateAcceptsPinnedLeaf() {
        let leaf = certificate(Self.leafValidB64)
        let delegate = BridgePinnedTrustDelegate(pinProvider: { [self.pin(for: leaf)] })
        let (disposition, credential) = delegate.disposition(for: makeTrust([leaf]))
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential)
    }

    // MARK: - Pairing capture (TOFU) + continuity

    func testPairingCaptureAcceptsSelfSignedBridgeLeaf() {
        let leaf = certificate(Self.leafValidB64)
        let capture = BridgeTrust.pairingCapture(trust: makeTrust([leaf]))
        XCTAssertNotNil(capture)
        XCTAssertEqual(capture?.bridgeID, Self.bridgeID)
        XCTAssertEqual(capture?.caValidated, false)
    }

    func testPairingCaptureClassifiesCAValidatedLeaf() {
        let caLeaf = certificate(Self.leafCASignedB64)
        let testCA = certificate(Self.testCAB64)
        let capture = BridgeTrust.pairingCapture(trust: makeTrust([caLeaf, testCA]), roots: [testCA])
        XCTAssertNotNil(capture)
        XCTAssertEqual(capture?.caValidated, true)
    }

    func testPairingCaptureRejectsNonBridgeCN() {
        let evil = certificate(Self.leafWrongCNB64)
        XCTAssertNil(BridgeTrust.pairingCapture(trust: makeTrust([evil])),
                     "a leaf whose CN is not a 16-hex bridgeid must never be captured")
    }

    func testPairingDelegateEnforcesSameLeafContinuity() {
        let delegate = BridgePairingTrustDelegate()
        let first = delegate.disposition(for: makeTrust([certificate(Self.leafValidB64)]))
        XCTAssertEqual(first.0, .useCredential)

        // A different leaf mid-session (relay/downgrade attempt) is rejected,
        // mirroring Android's D-014 GET→POST identity continuity.
        let second = delegate.disposition(for: makeTrust([certificate(Self.leafImpersonatorB64)]))
        XCTAssertEqual(second.0, .cancelAuthenticationChallenge)
        XCTAssertNil(second.1)

        // The original leaf keeps working.
        let third = delegate.disposition(for: makeTrust([certificate(Self.leafValidB64)]))
        XCTAssertEqual(third.0, .useCredential)
    }
}
