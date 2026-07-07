// BridgeDiscoveryViewModel.swift
// CastChroma — Epic 1 / Story 1.1 (rev 2)
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

// MARK: - NUPnP Cloud Discovery Response

private struct NUPnPResult: Decodable {
    let id: String
    let internalipaddress: String
    let port: Int?
}

// The former trust-all BridgeCertTrustDelegate (audit H-02) was replaced by
// BridgePairingTrustDelegate in Core/Network/Trust/ (D-016): it validates the
// chain + 16-hex bridgeid CN, captures the leaf for pinning, and enforces
// same-leaf continuity across the pairing session.

// MARK: - BridgeDiscoveryViewModel

@Observable
@MainActor
final class BridgeDiscoveryViewModel {

    // MARK: State
    var phase: DiscoveryPhase = .idle
    var logLines: [String] = []
    /// L-15: the freshly minted BridgeRecord id whose per-bridge namespaced
    /// Keychain slots received this pairing's credentials. Set on every
    /// successful pairing BEFORE `phase` becomes `.paired`, so the setup view
    /// can create the record atomically with the already-persisted credentials.
    private(set) var pairedRecordID: String?
    /// Canonical uppercase 16-hex Hue bridgeid established during identity
    /// verification (L-17 dedup key). nil when the test seam bypassed
    /// verification or the legacy pin path could not recover it.
    private(set) var pairedCanonicalBridgeID: String?
    /// Human-readable label shown in the scanning UI — updates as fallback methods are tried.
    var scanningLabel: String = "Searching your Wi-Fi..."
    /// Host+port-deduplicated bridges available for explicit selection during scanning.
    var discoveredBridgeChoices: [BridgeEndpoint] = []

    // MARK: Services
    let discovery = BridgeDiscoveryService()
    /// Test seam: when set, the pairing POST uses this session instead of the
    /// internally constructed one, so tests can stub responses via URLProtocol.
    @ObservationIgnored var pairingSessionOverride: URLSession?
    /// Test seam: replaces the post-pairing identity verification + pinning
    /// (URLProtocol stubs cannot present a real server trust to capture).
    @ObservationIgnored var pinAcquisitionOverride: ((BridgeEndpoint) async -> Bool)?
    private var cancellables = Set<AnyCancellable>()
    private var scanTimeoutTask: Task<Void, Never>?
    private var mdnsRetryDone = false   // guards the silent mDNS warm-cache retry
    private let log = Logger(subsystem: "com.lightshade.app", category: "ViewModel.Discovery")

    // MARK: Init
    init() {
        // Forward log lines from the discovery service
        discovery.$logLines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in
                self?.logLines = lines
            }
            .store(in: &cancellables)

        // Keep scanning until the user explicitly selects a discovered bridge.
        discovery.$discoveredBridges
            .receive(on: RunLoop.main)
            .sink { [weak self] bridges in
                guard let self else { return }
                let deduped = Self.deduplicatedByHostAndPort(bridges)
                let previousKeys = Set(self.discoveredBridgeChoices.map { Self.endpointKey($0) })
                for bridge in deduped where !previousKeys.contains(Self.endpointKey(bridge)) {
                    self.appendLog("🌉 Resolved bridge choice: '\(bridge.name)' @ \(bridge.host):\(bridge.port)")
                    StartupTimeline.mark("discovery.mdns-found", "\(bridge.host):\(bridge.port)")
                }
                self.discoveredBridgeChoices = deduped
            }
            .store(in: &cancellables)
        StartupTimeline.mark("discovery.vm-init.done")
    }

    /// Collapses duplicate mDNS resolutions that share the same host and port.
    nonisolated static func deduplicatedByHostAndPort(_ bridges: [BridgeEndpoint]) -> [BridgeEndpoint] {
        var seen = Set<String>()
        var result: [BridgeEndpoint] = []
        for bridge in bridges {
            let key = endpointKey(bridge)
            guard seen.insert(key).inserted else { continue }
            result.append(bridge)
        }
        return result
    }

    private nonisolated static func endpointKey(_ bridge: BridgeEndpoint) -> String {
        "\(bridge.host):\(bridge.port)"
    }

    // ──────────────────────────────────────────────
    // MARK: - Scan Control
    // ──────────────────────────────────────────────

    func startScan() {
        // Allow retry from idle or any error state
        switch phase {
        case .idle, .error: break
        default: return
        }

        logLines.removeAll()
        discoveredBridgeChoices.removeAll()
        phase = .scanning
        scanningLabel = "Searching your Wi-Fi..."
        mdnsRetryDone = false
        appendLog("▶️  Scan initiated — mDNS (layer 1).")
        StartupTimeline.mark("discovery.scan-start")
        discovery.startScan()

        // ── Layer 2: NUPnP fallback after 12 s if mDNS finds nothing ──
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, case .scanning = self.phase else { return }
            // M-11: the design stays .scanning while mDNS results accumulate
            // in the chooser — the cloud fallback must never run once local
            // bridges exist (an empty NUPnP reply bounced the user to an
            // error screen; a non-empty one force-selected and hid choices).
            guard self.discoveredBridgeChoices.isEmpty else {
                self.appendLog("⏱ mDNS already found \(self.discoveredBridgeChoices.count) bridge(s) — cloud fallback skipped.")
                return
            }
            self.appendLog("⏱ mDNS timeout — falling back to Philips cloud discovery (layer 2).")
            StartupTimeline.mark("discovery.mdns-timeout", "12s, nothing found")
            await MainActor.run { self.scanningLabel = "Trying cloud discovery..." }
            await self.discoverViaNUPnP()
        }
    }

    func resetToIdle() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        discovery.stopScan()
        discoveredBridgeChoices.removeAll()
        phase = .idle
        appendLog("🔄 Reset to idle.")
    }

    /// User picked a discovered bridge; stop scanning and show pairing instructions for that endpoint.
    func selectDiscoveredBridge(_ bridge: BridgeEndpoint) {
        guard case .scanning = phase else { return }
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        discovery.stopScan()
        appendLog("👆 Selected discovered bridge: '\(bridge.name)' @ \(bridge.host):\(bridge.port)")
        appendLog("👆 Press the link button on your Hue Bridge, then tap Pair.")
        phase = .bridgeFound(bridge)
    }

    // ──────────────────────────────────────────────
    // MARK: - NUPnP Cloud Discovery (Layer 2)
    // ──────────────────────────────────────────────

    /// Calls Philips' internet-based discovery endpoint as a fallback when
    /// mDNS is blocked by the router (AP isolation, IGMP filtering, etc.).
    /// Internal (not private) so the M-11 guard is unit-testable.
    func discoverViaNUPnP() async {
        // M-11: never let the cloud fallback override or wipe local results —
        // guarded on entry AND after the network call (mDNS can resolve while
        // the cloud GET is in flight).
        guard discoveredBridgeChoices.isEmpty else {
            appendLog("☁️  Cloud fallback skipped — \(discoveredBridgeChoices.count) local bridge(s) already found.")
            return
        }
        guard let url = URL(string: "https://discovery.meethue.com/api/nupnp") else { return }
        appendLog("☁️  GET https://discovery.meethue.com/api/nupnp")
        StartupTimeline.mark("discovery.nupnp-start")
        let __nupnpStart = Date()

        do {
            // Explicit 10s timeout (matches performPairingRequest). The bare
            // data(from:) call inherited URLSession's 60s default — the only
            // unbounded stall on the discovery path (offline / captive portal).
            let nupnpRequest = URLRequest(url: url, timeoutInterval: 10)
            let (data, _) = try await URLSession.shared.data(for: nupnpRequest)
            StartupTimeline.mark("discovery.nupnp-done", "\(Int(Date().timeIntervalSince(__nupnpStart) * 1000))ms \(data.count)B")

            if let raw = String(data: data, encoding: .utf8) {
                appendLog("   NUPnP response: \(raw)")
            }

            let results = try JSONDecoder().decode([NUPnPResult].self, from: data)

            guard discoveredBridgeChoices.isEmpty, case .scanning = phase else {
                appendLog("☁️  Local bridge(s) appeared during the cloud lookup — keeping the local chooser.")
                return
            }

            guard let first = results.first else {
                discovery.stopScan()
                handleError("No bridge found automatically.\n\nMake sure your Hue Bridge is powered on and connected to Wi-Fi, then try again — or enter your bridge IP manually.")
                return
            }

            let port = UInt16(first.port ?? 443)
            let bridge = BridgeEndpoint(name: "Philips Hue Bridge", host: first.internalipaddress, port: port)
            discovery.stopScan()
            appendLog("✅ NUPnP found bridge at \(bridge.host):\(bridge.port)")
            phase = .bridgeFound(bridge)

        } catch {
            StartupTimeline.mark("discovery.nupnp-FAIL", "\(Int(Date().timeIntervalSince(__nupnpStart) * 1000))ms \(error.localizedDescription)")
            appendLog("❌ NUPnP error: \(error.localizedDescription)")

            // M-11: bridges resolved while the cloud GET was failing — the
            // silent mDNS retry below restarts the browser, which would WIPE
            // the chooser. Keep the local results instead.
            guard discoveredBridgeChoices.isEmpty else {
                appendLog("☁️  Keeping \(discoveredBridgeChoices.count) locally discovered bridge(s) — select one below.")
                return
            }

            guard !mdnsRetryDone else {
                // Already retried once — give up
                discovery.stopScan()
                handleError("Bridge not found automatically.\n\nCheck your Wi-Fi connection or tap \"Enter IP Manually\" to connect directly.")
                return
            }

            // ── Silent mDNS retry ──────────────────────────────────────────────
            // NUPnP failed but the first mDNS pass already warmed the OS's
            // DNS-SD / mDNSResponder cache. Restarting the scan now means the
            // SRV→A lookup is instant and the NWConnection TCP handshake
            // completes in < 1 s instead of timing out.
            mdnsRetryDone = true
            appendLog("🔄 NUPnP unavailable — restarting mDNS with warm cache…")
            scanningLabel = "Still searching…"
            discovery.stopScan()

            // Brief pause so the NWBrowser teardown completes cleanly
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard case .scanning = phase else { return }   // user cancelled during pause

            discovery.startScan()

            // Poll up to 10 s for mDNS resolution (0.5 s intervals → 20 checks); user selects from the chooser.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard case .scanning = phase else { return }
            }

            guard case .scanning = phase else { return }
            if discoveredBridgeChoices.isEmpty {
                discovery.stopScan()
                handleError("Bridge not found automatically.\n\nCheck your Wi-Fi connection or tap \"Enter IP Manually\" to connect directly.")
            } else {
                appendLog("✅ mDNS retry found \(discoveredBridgeChoices.count) bridge(s) — select one below.")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Pairing
    // ──────────────────────────────────────────────

    /// Called after the user has pressed the physical link button on the Bridge.
    func pairWithBridge(_ bridge: BridgeEndpoint) {
        pairedRecordID = nil
        pairedCanonicalBridgeID = nil
        phase = .pairing(bridge)
        StartupTimeline.mark("pairing.begin", "\(bridge.host):\(bridge.port)")
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
            "devicetype": AppBrand.hueDeviceType,
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

        // For HTTPS, use a TOFU-capture session that validates the bridge leaf
        // (chain evaluation + 16-hex bridgeid CN) and records it for pinning
        // (H-02/D-016). For legacy HTTP pairing the POST goes over .shared and
        // the pin is acquired over HTTPS in verifyBridgeIdentityAndPin.
        let session: URLSession
        var trustDelegate: BridgePairingTrustDelegate?
        var ownsSession = false
        if let override = pairingSessionOverride {
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
                log.warning("Pairing: Bridge error \(err.type): \(err.description).")
                // Return to bridgeFound so user can retry
                phase = .bridgeFound(bridge)
                return
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
                    handleError("Could not verify this bridge's secure identity. Make sure you are on the same network as the bridge, then try pairing again.")
                    return
                }

                // L-15: persist straight to per-bridge NAMESPACED Keychain
                // slots keyed by a freshly minted BridgeRecord id. The legacy
                // single-bridge slots (hue_api_token/hue_bridge_ip) are never
                // written here anymore — a second pairing in the same session
                // used to overwrite them and silently drop the first bridge's
                // credentials on relaunch.
                let recordID = UUID().uuidString
                do {
                    try KeychainManager.shared.saveCredentials(
                        ip: bridge.host,
                        token: token,
                        clientKey: clientKey.isEmpty ? nil : clientKey,
                        for: recordID
                    )
                } catch {
                    handleError("Could not save the bridge credentials to the Keychain: \(error.localizedDescription)")
                    return
                }
                pairedRecordID = recordID

                appendLog("💾 Credentials saved to per-bridge Keychain slots.")
                StartupTimeline.mark("pairing.success", bridge.host)
                phase = .paired(ip: bridge.host, token: token)

            } else {
                handleError("Unexpected response structure — no success or error block.")
            }

        } catch let decodeError as DecodingError {
            appendLog("❌ JSON decode error: \(decodeError)")
            log.error("Pairing: Decode error — \(String(describing: decodeError)).")
            handleError("Response decode failed. Check console for details.")
        } catch {
            appendLog("❌ Network error: \(error.localizedDescription)")
            log.error("Pairing: Network error — \(error.localizedDescription).")
            handleError(error.localizedDescription)
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

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func handleError(_ message: String) {
        appendLog("💥 \(message)")
        log.error("ViewModel: \(message).")
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
