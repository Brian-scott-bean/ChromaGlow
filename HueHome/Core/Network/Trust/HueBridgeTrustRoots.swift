// HueBridgeTrustRoots.swift
// ChromaGlow — Bridge TLS trust (audit H-01/H-02/M-01, Decision D-016)
//
// The two Philips Hue / Signify root CA certificates, embedded as DER so they
// are available in every target that talks to a bridge (app, widget, watch)
// without bundle-resource wiring. Byte-identical to the Android Batch-3 roots
// (android/app/src/main/res/raw on main; provenance and acceptance: pipeline
// Decision Log D-001/D-012, human-verified fingerprints recorded in D-016).
//
// A regression test asserts the SHA-256 fingerprints below, so swapped or
// corrupted bytes fail the suite, not the field.

import Foundation
import Security

enum HueBridgeTrustRoots {

    /// C=NL, O=Philips Hue, CN=root-bridge (self-signed, 2017–2038).
    /// SHA-256: F0BD8E6509E82F774D63BC009D5388C969FE3DCF7D6D541D6351B72B898D8ACF
    private static let rootBridgeDERBase64 = """
        MIICMjCCAdigAwIBAgIUO7FSLbaxikuXAljzVaurLXWmFw4wCgYIKoZIzj0EAwIwOTELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRQwEgYDVQQDDAtyb290LWJyaWRnZTAiGA8yMDE3MDEwMTAwMDAwMFoYDzIwMzgwMTE5MDMxNDA3WjA5MQswCQYDVQQGEwJOTDEUMBIGA1UECgwLUGhpbGlwcyBIdWUxFDASBgNVBAMMC3Jvb3QtYnJpZGdlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjNw2tx2AplOf9x86aTdvEcL1FU65QDxziKvBpW9XXSIcibAeQiKxegpq8Exbr9v6LBnYbna2VcaK0G22jOKkTqOBuTCBtjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNVHQ4EFgQUZ2ONTFrDT6o8ItRnKfqWKnHFGmQwdAYDVR0jBG0wa4AUZ2ONTFrDT6o8ItRnKfqWKnHFGmShPaQ7MDkxCzAJBgNVBAYTAk5MMRQwEgYDVQQKDAtQaGlsaXBzIEh1ZTEUMBIGA1UEAwwLcm9vdC1icmlkZ2WCFDuxUi22sYpLlwJY81Wrqy11phcOMAoGCCqGSM49BAMCA0gAMEUCIEBYYEOsa07TH7E5MJnGw557lVkORgit2Rm1h3B2sFgDAiEA1Fj/C3AN5psFMjo0//mrQebo0eKd3aWRx+pQY08mk48=
        """

    /// C=NL, O=Signify Hue, CN=Hue Root CA 01 (self-signed, 2025–2050).
    /// SHA-256: D8B89448B2AF8E1676185AC07219EE9DCBC8F01C122A026A2A4B7B5CFE0328B8
    private static let hueRootCA01DERBase64 = """
        MIIBzDCCAXOgAwIBAgICEAAwCgYIKoZIzj0EAwIwPDELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1NpZ25pZnkgSHVlMRcwFQYDVQQDDA5IdWUgUm9vdCBDQSAwMTAgFw0yNTAyMjUwMDAwMDBaGA8yMDUwMTIzMTIzNTk1OVowPDELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1NpZ25pZnkgSHVlMRcwFQYDVQQDDA5IdWUgUm9vdCBDQSAwMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABFfOO0jfSAUXGQ9kjEDzyBrcMQ3ItyA5krE+cyvb1Y3xFti7KlAad8UOnAx0FBLn7HZrlmIwm1QnX0fK3LPM13mjYzBhMB0GA1UdDgQWBBTF1pSpsCASX/z0VHLigxU2CAaqoTAfBgNVHSMEGDAWgBTF1pSpsCASX/z0VHLigxU2CAaqoTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNHADBEAiAk7duT+IHbOGO4UUuGLAEpyYejGZK9Z7V9oSfnvuQ5BQIgIYSgwwxHXm73/JgcU9lAM6c8Bmu3UE3kBIUwBs1qXFw=
        """

    /// Uppercase-hex SHA-256 fingerprints of the two roots, as verified by the
    /// human collaborator (chromaglow-hue-ca VERIFICATION.md, 2026-06-29).
    static let expectedSHA256Fingerprints: Set<String> = [
        "F0BD8E6509E82F774D63BC009D5388C969FE3DCF7D6D541D6351B72B898D8ACF",
        "D8B89448B2AF8E1676185AC07219EE9DCBC8F01C122A026A2A4B7B5CFE0328B8",
    ]

    /// The bundled root anchors. Empty only if the embedded bytes are corrupt,
    /// which the fingerprint regression test catches at CI time.
    static let all: [SecCertificate] = {
        [rootBridgeDERBase64, hueRootCA01DERBase64].compactMap { base64 in
            guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }()
}
