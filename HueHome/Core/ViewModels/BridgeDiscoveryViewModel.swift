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

// The Hue pairing response models and the identity-gated POST itself moved to
// Core/Network/ApplicationKeyMinter.swift (Family Sharing Phase 2) so the
// normal pairing flow and owner-side guest-key minting share one audited path.

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
    /// Invite trust rule (home-join QR): when set, a successful pairing must
    /// ALSO match this identity — canonical bridgeid AND the live-captured
    /// leaf-key pin. The QR's pin is verified-against, never ingested: a
    /// wrong or tampered invite can only cause a refusal here, it can never
    /// inject trust. Checked after verifyBridgeIdentityAndPin, BEFORE any
    /// credential persists.
    var expectedIdentity: (bridgeID: String, publicKeySHA256: String)?
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
        // Philips retired the /api/nupnp path (it now returns "404 page not
        // found" — observed on device 2026-07-07); the JSON lives at the root.
        guard let url = URL(string: "https://discovery.meethue.com/") else { return }
        appendLog("☁️  GET https://discovery.meethue.com/")
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
        // The identity-gated POST lives in ApplicationKeyMinter (shared with
        // owner-side guest-key minting, Phase 2). The minter emits the exact
        // log lines this flow always produced; the VM keeps what makes the
        // flow a *pairing*: phase transitions, Keychain persistence, and the
        // StartupTimeline mark.
        let minter = ApplicationKeyMinter(
            appendLog: { [weak self] in self?.appendLog($0) },
            log: log
        )
        minter.sessionOverride = pairingSessionOverride
        minter.pinAcquisitionOverride = pinAcquisitionOverride

        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.hueDeviceType,
            generateClientKey: true,       // Needed for Entertainment API (Epic 4)
            expectedIdentity: expectedIdentity
        )

        switch result {
        case .success(let minted):
            pairedCanonicalBridgeID = minted.canonicalBridgeID

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
                    token: minted.token,
                    clientKey: minted.clientKey,
                    for: recordID
                )
            } catch {
                handleError("Could not save the bridge credentials to the Keychain: \(error.localizedDescription)")
                return
            }
            pairedRecordID = recordID

            appendLog("💾 Credentials saved to per-bridge Keychain slots.")
            StartupTimeline.mark("pairing.success", bridge.host)
            phase = .paired(ip: bridge.host, token: minted.token)

        case .failure(let error):
            switch error {
            case .bridgeRefused:
                // Warning already logged by the minter — return to bridgeFound
                // so the user can retry after pressing the link button.
                phase = .bridgeFound(bridge)
            case .invalidURL(let host):
                handleError("Invalid bridge URL for host: \(host)")
            case .bodyEncodeFailed(let message):
                handleError("JSON encode failure: \(message)")
            case .emptyResponse:
                handleError("Empty response array from Bridge.")
            case .unexpectedResponse:
                handleError("Unexpected response structure — no success or error block.")
            case .identityVerificationFailed:
                handleError("Could not verify this bridge's secure identity. Make sure you are on the same network as the bridge, then try pairing again.")
            case .expectedIdentityMismatch:
                handleError("This bridge doesn't match the invite. Make sure you're on the inviter's Wi-Fi and scanning their current QR, then try again.")
            case .decodeFailed:
                handleError("Response decode failed. Check console for details.")
            case .network(let message):
                handleError(message)
            }
        }
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
