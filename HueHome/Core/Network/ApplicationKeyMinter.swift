// ApplicationKeyMinter.swift
// ChromaGlow — Family Sharing Phase 2 (per-guest app keys)
//
// The identity-gated Hue application-key mint, extracted verbatim from
// BridgeDiscoveryViewModel.performPairingRequest so BOTH callers share one
// audited path:
//   - the normal pairing flow (devicetype "chromaglow#ios",
//     generateclientkey: true), and
//   - owner-side guest-key minting (devicetype "chromaglow#g-<slug>",
//     generateclientkey: false — a guest key must never carry an
//     entertainment clientkey, design doc §7.3).
//
// The minter owns: POST /api, response decoding, bridge-error mapping,
// TLS TOFU capture (D-016), /api/0/config bridgeid cross-check, and the
// invite expectedIdentity refusal (pins are verified-against, never
// ingested). It does NOT own phase transitions, Keychain writes, or
// StartupTimeline marks — those stay with the caller so the normal
// pairing flow's observable behavior is unchanged.
//
// Design: docs/ios/profiles-access-share-invite-design-2026-07.md §6.2.

import Foundation
import OSLog

// MARK: - Hue Pairing Response Models

private struct PairingResponse: Decodable {
    let success: PairingSuccess?
    let error: PairingErr?
}

private struct PairingSuccess: Decodable {
    let username: String
    let clientkey: String?
}

private struct PairingErr: Decodable {
    let type: Int
    let address: String
    let description: String
}

// MARK: - Result / Error types

struct MintedApplicationKey {
    let token: String
    /// Always nil when the mint requested `generateclientkey: false`.
    let clientKey: String?
    /// Canonical uppercase 16-hex bridgeid established during identity
    /// verification. nil when a test seam bypassed verification or the
    /// legacy pin path could not recover it.
    let canonicalBridgeID: String?
}

enum ApplicationKeyMintError: Error, Equatable {
    case invalidURL(host: String)
    case bodyEncodeFailed(String)
    case emptyResponse
    case unexpectedResponse
    /// Bridge-level refusal. type 101 = link button not pressed (retryable).
    case bridgeRefused(type: Int, description: String)
    case identityVerificationFailed
    case expectedIdentityMismatch
    case decodeFailed(String)
    case network(String)
}

// MARK: - ApplicationKeyMinter

@MainActor
final class ApplicationKeyMinter {

    /// Test seam: when set, the pairing POST uses this session instead of the
    /// internally constructed one, so tests can stub responses via URLProtocol.
    var sessionOverride: URLSession?
    /// Test seam: replaces the post-mint identity verification + pinning
    /// (URLProtocol stubs cannot present a real server trust to capture).
    var pinAcquisitionOverride: ((BridgeEndpoint) async -> Bool)?

    /// Canonical bridgeid recovered by the most recent successful mint's
    /// identity verification (also surfaced in MintedApplicationKey).
    private(set) var pairedCanonicalBridgeID: String?

    private let appendLog: (String) -> Void
    private let log: Logger

    init(appendLog: @escaping (String) -> Void,
         log: Logger = Logger(subsystem: "com.lightshade.app", category: "ApplicationKeyMinter")) {
        self.appendLog = appendLog
        self.log = log
    }

    // ──────────────────────────────────────────────
    // MARK: - Guest devicetype (Phase 2)
    // ──────────────────────────────────────────────

    /// Builds the device segment for a guest devicetype:
    /// "g-<slug≤12>-<4 hex of profileID>", always ≤ 19 chars (the Hue
    /// devicetype device-segment limit), charset [a-z0-9-].
    nonisolated static func guestDeviceSegment(profileName: String, profileID: String) -> String {
        var slug = profileName.lowercased()
            .map { ch -> Character in
                if ch.isLetter && ch.isASCII { return ch }
                if ch.isNumber && ch.isASCII { return ch }
                return "-"
            }
            .reduce(into: "") { partial, ch in
                // collapse runs of '-'
                if ch == "-", partial.hasSuffix("-") { return }
                partial.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "guest" }
        slug = String(slug.prefix(12))
        while slug.hasSuffix("-") { slug.removeLast() }

        let hex = profileID.lowercased().filter(\.isHexDigit)
        let suffix = String(hex.prefix(4)).isEmpty ? "0000" : String(hex.prefix(4))
        return "g-\(slug)-\(suffix)"
    }

    // ──────────────────────────────────────────────
    // MARK: - Mint
    // ──────────────────────────────────────────────

    /// Performs the identity-gated key mint against `endpoint`. Logs are
    /// emitted through `appendLog` with the exact strings the pairing flow
    /// has always produced (H-04: never the key material, never the raw
    /// response). Nothing is persisted here — the caller owns Keychain and
    /// record creation, and a refusal therefore leaves no trace.
    func mint(endpoint bridge: BridgeEndpoint,
              devicetype: String,
              generateClientKey: Bool,
              expectedIdentity: (bridgeID: String, publicKeySHA256: String)?
    ) async -> Result<MintedApplicationKey, ApplicationKeyMintError> {

        // Newer bridges use HTTPS on port 443; older use HTTP on port 80.
        let scheme = bridge.port == 443 ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(bridge.host):\(bridge.port)/api") else {
            return .failure(.invalidURL(host: bridge.host))
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "devicetype": devicetype,
            "generateclientkey": generateClientKey   // false for guest keys — no DTLS entitlement
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.bodyEncodeFailed(error.localizedDescription))
        }

        appendLog("📤 POST \(url.absoluteString)")
        appendLog("   Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        // For HTTPS, use a TOFU-capture session that validates the bridge leaf
        // (chain evaluation + 16-hex bridgeid CN) and records it for pinning
        // (H-02/D-016). For legacy HTTP pairing the POST goes over .shared and
        // the pin is acquired over HTTPS in verifyBridgeIdentityAndPin.
        let session: URLSession
        var trustDelegate: BridgePairingTrustDelegate?
        var ownsSession = false
        if let override = sessionOverride {
            session = override
        } else if bridge.port == 443 {
            let delegate = BridgePairingTrustDelegate()
            trustDelegate = delegate
            session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            ownsSession = true
            appendLog("🔐 HTTPS mode — pinned bridge trust (TOFU capture) enabled.")
        } else {
            session = .shared
        }
        // L-18: sessions created per pairing attempt must be invalidated or
        // each retry permanently leaks a session + delegate.
        defer { if ownsSession { session.finishTasksAndInvalidate() } }

        do {
            let (data, response) = try await session.data(for: request)

            // Log raw HTTP status
            if let http = response as? HTTPURLResponse {
                appendLog("📥 HTTP \(http.statusCode) from Bridge.")
                log.info("Pairing: HTTP \(http.statusCode, privacy: .public).")
            }

            // H-04: never log the raw pairing response — on success it contains
            // the application key AND the entertainment client key verbatim.
            appendLog("📥 Response received (\(data.count) bytes).")
            log.info("Pairing: response received (\(data.count, privacy: .public) bytes).")

            // Decode array response
            let responses = try JSONDecoder().decode([PairingResponse].self, from: data)

            guard let first = responses.first else {
                return .failure(.emptyResponse)
            }

            // Check for Bridge-level error (e.g. button not pressed)
            if let err = first.error {
                let desc: String
                switch err.type {
                case 101: desc = "Link button not pressed. Press the button on your Bridge, then tap Pair again."
                case 7:   desc = "Invalid value in body — check devicetype string."
                default:  desc = "Bridge error \(err.type): \(err.description)"
                }
                appendLog("⚠️  \(desc)")
                log.warning("Pairing: Bridge error \(err.type): \(err.description).")
                return .failure(.bridgeRefused(type: err.type, description: desc))
            }

            // Success path
            if let success = first.success {
                let token = success.username
                let clientKey = success.clientkey ?? ""

                // H-04: log only non-secret metadata — never the key material.
                appendLog("✅ Paired! Application key received (\(token.count) chars).")
                if !clientKey.isEmpty {
                    appendLog("🔑 Entertainment client key received (\(clientKey.count) chars).")
                }
                log.info("Pairing: Success. Token length: \(token.count).")

                // H-02/D-016: bind this pairing to the bridge's cryptographic
                // identity BEFORE persisting anything. On failure, nothing is
                // stored and the pairing is aborted.
                guard await verifyBridgeIdentityAndPin(
                    bridge: bridge,
                    session: session,
                    capture: trustDelegate?.capture
                ) else {
                    return .failure(.identityVerificationFailed)
                }

                // Invite flow only: the just-verified live identity must match
                // the invite's expectation. Nothing has persisted app-side yet,
                // so refusing here leaves no trace to clean up.
                if let expected = expectedIdentity {
                    let canonical = pairedCanonicalBridgeID ?? ""
                    let livePin = BridgePinStore.shared
                        .pin(forBridgeID: canonical)?.publicKeySHA256
                    guard canonical == expected.bridgeID.uppercased(),
                          livePin == expected.publicKeySHA256 else {
                        appendLog("⛔️ Invite identity mismatch — refusing pairing.")
                        return .failure(.expectedIdentityMismatch)
                    }
                    appendLog("🪪 Invite identity confirmed — bridge matches the QR.")
                }

                return .success(MintedApplicationKey(
                    token: token,
                    clientKey: clientKey.isEmpty ? nil : clientKey,
                    canonicalBridgeID: pairedCanonicalBridgeID
                ))

            } else {
                return .failure(.unexpectedResponse)
            }

        } catch let decodeError as DecodingError {
            appendLog("❌ JSON decode error: \(decodeError)")
            log.error("Pairing: Decode error — \(String(describing: decodeError)).")
            return .failure(.decodeFailed(String(describing: decodeError)))
        } catch {
            appendLog("❌ Network error: \(error.localizedDescription)")
            log.error("Pairing: Network error — \(error.localizedDescription).")
            return .failure(.network(error.localizedDescription))
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Bridge Identity Verification (D-016)
    // ──────────────────────────────────────────────

    /// Fetches `/api/0/config`, requires `bridgeid` == the captured leaf CN,
    /// then pins the leaf. For HTTPS pairing the config GET rides the SAME
    /// session, so BridgePairingTrustDelegate enforces same-leaf continuity
    /// across both legs (mirrors Android D-014). For legacy HTTP pairing
    /// (no TLS handshake, no capture) a fresh TOFU session acquires the pin —
    /// the data plane is HTTPS-only, so a bridge without a valid HTTPS
    /// identity cannot be used and pairing fails closed.
    private func verifyBridgeIdentityAndPin(
        bridge: BridgeEndpoint,
        session: URLSession,
        capture: PairingLeafCapture?
    ) async -> Bool {
        if let override = pinAcquisitionOverride {
            return await override(bridge)
        }
        guard let capture else {
            appendLog("🔒 Acquiring HTTPS identity pin for legacy-paired bridge…")
            let pinned = await BridgePinAcquirer.acquirePin(host: bridge.host)
            if !pinned {
                appendLog("❌ Bridge does not present a valid HTTPS identity — cannot pair securely.")
            } else {
                // L-17: the acquired pin records the canonical bridgeid for
                // this host — recover it so the record dedup can use it.
                pairedCanonicalBridgeID = BridgePinStore.shared.loadPins()
                    .first { $0.host == bridge.host }?.bridgeID
            }
            return pinned
        }
        guard let url = URL(string: "https://\(bridge.host)/api/0/config") else { return false }
        // A transient hiccup here would otherwise discard a just-issued
        // application key and force another link-button press — retry the
        // cheap unauthenticated config GET a couple of times first.
        var configBridgeID: String?
        for attempt in 1...3 {
            do {
                let (data, _) = try await session.data(from: url)
                guard let parsed = BridgeTrust.bridgeID(fromConfigResponse: data) else {
                    appendLog("❌ Bridge config did not return a valid bridgeid.")
                    return false
                }
                configBridgeID = parsed
                break
            } catch {
                appendLog("⚠️ Bridge config fetch attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        guard let configBridgeID else {
            appendLog("❌ Could not verify bridge identity — config fetch failed.")
            return false
        }
        // Interactive pairing: the user just pressed the physical link button,
        // so a self-signed legacy bridge may be pinned here (unattended: false).
        guard BridgePinAcquirer.validateAndPersist(
            capture: capture, configBridgeID: configBridgeID, host: bridge.host, unattended: false
        ) else {
            appendLog("❌ Bridge identity check failed — certificate does not match this bridge's known identity. If you replaced or factory-reset the bridge, remove it in Settings first, then pair again.")
            return false
        }
        appendLog("🔒 Bridge TLS identity verified and pinned (\(configBridgeID)).")
        pairedCanonicalBridgeID = configBridgeID
        return true
    }
}
