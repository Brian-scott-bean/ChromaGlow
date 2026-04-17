// BridgeDiscoveryViewModel.swift
// HueHome Pro — Epic 1 / Story 1.1 (rev 2)
//
// State machine for the full Hue Bridge handshake:
//   .idle → .scanning → .bridgeFound → .awaitingPair → .pairing → .paired / .error

import Foundation
import Combine
import OSLog

// MARK: - Discovery Phase

enum DiscoveryPhase: Equatable {
    case idle
    case scanning
    case bridgeFound(BridgeEndpoint)    // mDNS resolved; waiting for user to press link button
    case pairing(BridgeEndpoint)        // POST /api in flight
    case paired(ip: String, token: String)
    case error(String)

    static func == (lhs: DiscoveryPhase, rhs: DiscoveryPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.scanning, .scanning): return true
        case (.bridgeFound(let a), .bridgeFound(let b)): return a == b
        case (.pairing(let a), .pairing(let b)): return a == b
        case (.paired(let a, let b), .paired(let c, let d)): return a == c && b == d
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

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

// MARK: - Self-Signed Certificate Trust Delegate
//
// Newer Hue Bridges (Square v2, v3) serve HTTPS on port 443 with a Signify-issued
// self-signed certificate. URLSession rejects it by default. This delegate
// accepts it unconditionally on the local network.
// ⚠️ ONLY used for local-network LAN connections — never for public Internet URLs.

private final class BridgeCertTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Trust the bridge's self-signed cert on local network
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

// MARK: - BridgeDiscoveryViewModel

@Observable
@MainActor
final class BridgeDiscoveryViewModel {

    // MARK: State
    var phase: DiscoveryPhase = .idle
    var logLines: [String] = []

    // MARK: Services
    let discovery = BridgeDiscoveryService()
    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: "com.huehome.pro", category: "ViewModel.Discovery")

    // MARK: Init
    init() {
        // Forward log lines from the discovery service
        discovery.$logLines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in
                self?.logLines = lines
            }
            .store(in: &cancellables)

        // Auto-transition to .bridgeFound when the first bridge resolves via mDNS
        discovery.$discoveredBridges
            .filter { !$0.isEmpty }
            .compactMap { $0.first }
            .first()                      // only fire once per scan session
            .receive(on: RunLoop.main)
            .sink { [weak self] bridge in
                guard let self else { return }
                guard case .scanning = self.phase else { return }
                self.discovery.stopScan()
                self.appendLog("🎉 Bridge found via mDNS: '\(bridge.name)' @ \(bridge.host):\(bridge.port)")
                self.appendLog("👆 Press the link button on your Hue Bridge, then tap Pair.")
                self.phase = .bridgeFound(bridge)
            }
            .store(in: &cancellables)
    }

    // ──────────────────────────────────────────────
    // MARK: - Scan Control
    // ──────────────────────────────────────────────

    func startScan() {
        guard phase == .idle || phase == .error("") || {
            if case .error = phase { return true }
            return false
        }() else { return }

        logLines.removeAll()
        phase = .scanning
        appendLog("▶️  Scan initiated.")
        discovery.startScan()
    }

    func resetToIdle() {
        discovery.stopScan()
        phase = .idle
        appendLog("🔄 Reset to idle.")
    }

    // ──────────────────────────────────────────────
    // MARK: - Pairing
    // ──────────────────────────────────────────────

    /// Called after the user has pressed the physical link button on the Bridge.
    func pairWithBridge(_ bridge: BridgeEndpoint) {
        phase = .pairing(bridge)
        let scheme = bridge.port == 443 ? "https" : "http"
        appendLog("🤝 Attempting pairing POST to \(scheme)://\(bridge.host):\(bridge.port)/api …")

        Task {
            await performPairingRequest(bridge: bridge)
        }
    }

    private func performPairingRequest(bridge: BridgeEndpoint) async {
        // Newer bridges use HTTPS on port 443; older use HTTP on port 80.
        let scheme = bridge.port == 443 ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(bridge.host):\(bridge.port)/api") else {
            handleError("Invalid bridge URL for host: \(bridge.host)")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "devicetype": "huehome#pro",
            "generateclientkey": true       // Needed for Entertainment API (Epic 4)
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            handleError("JSON encode failure: \(error.localizedDescription)")
            return
        }

        appendLog("📤 POST \(url.absoluteString)")
        appendLog("   Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        // For HTTPS, use a custom session that trusts the Bridge self-signed cert.
        // For HTTP, URLSession.shared is fine.
        let session: URLSession
        if bridge.port == 443 {
            let delegate = BridgeCertTrustDelegate()
            session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            appendLog("🔐 HTTPS mode — using Bridge certificate trust delegate.")
        } else {
            session = .shared
        }

        do {
            let (data, response) = try await session.data(for: request)

            // Log raw HTTP status
            if let http = response as? HTTPURLResponse {
                appendLog("📥 HTTP \(http.statusCode) from Bridge.")
                log.info("Pairing: HTTP \(http.statusCode, privacy: .public).")
            }

            // Log raw JSON for debugging
            if let raw = String(data: data, encoding: .utf8) {
                appendLog("   Raw response: \(raw)")
                log.info("Pairing: Raw response: \(raw, privacy: .public).")
            }

            // Decode array response
            let responses = try JSONDecoder().decode([PairingResponse].self, from: data)

            guard let first = responses.first else {
                handleError("Empty response array from Bridge.")
                return
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
                log.warning("Pairing: Bridge error \(err.type): \(err.description, privacy: .public).")
                // Return to bridgeFound so user can retry
                phase = .bridgeFound(bridge)
                return
            }

            // Success path
            if let success = first.success {
                let token = success.username
                let clientKey = success.clientkey ?? ""

                appendLog("✅ Paired! Application Key: \(token)")
                if !clientKey.isEmpty {
                    appendLog("🔑 Client Key (Entertainment): \(clientKey)")
                }
                log.info("Pairing: Success. Token length: \(token.count).")

                // Persist both to Keychain
                try KeychainManager.shared.saveAPIToken(token)
                try KeychainManager.shared.saveBridgeIP(bridge.host)

                if !clientKey.isEmpty {
                    try? KeychainManager.shared.save(value: clientKey, for: "hue_client_key")
                }

                appendLog("💾 Token and Bridge IP saved to Keychain.")
                phase = .paired(ip: bridge.host, token: token)

            } else {
                handleError("Unexpected response structure — no success or error block.")
            }

        } catch let decodeError as DecodingError {
            appendLog("❌ JSON decode error: \(decodeError)")
            log.error("Pairing: Decode error — \(String(describing: decodeError), privacy: .public).")
            handleError("Response decode failed. Check console for details.")
        } catch {
            appendLog("❌ Network error: \(error.localizedDescription)")
            log.error("Pairing: Network error — \(error.localizedDescription, privacy: .public).")
            handleError(error.localizedDescription)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func handleError(_ message: String) {
        appendLog("💥 \(message)")
        log.error("ViewModel: \(message, privacy: .public).")
        phase = .error(message)
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.logTime.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        logLines.append(line)
#if DEBUG
        #if DEBUG
        print(line)
        #endif
#endif
    }

    // ──────────────────────────────────────────────
    // MARK: - Convenience
    // ──────────────────────────────────────────────

    var savedBridgeIP: String? { try? KeychainManager.shared.loadBridgeIP() }
    var savedToken: String?    { try? KeychainManager.shared.loadAPIToken() }
}

// MARK: - DateFormatter

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
