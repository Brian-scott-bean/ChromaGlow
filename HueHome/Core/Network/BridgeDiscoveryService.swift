// BridgeDiscoveryService.swift
// CastChroma — Epic 1 / Story 1.1
//
// Uses Apple's Network framework (NWBrowser) to discover a Philips Hue Bridge
// on the local network via mDNS (_hue._tcp). Zero simulator fallbacks.
//
// Discovery lifecycle:
//   start() → NWBrowser scans for _hue._tcp endpoints
//   → Each endpoint is resolved to an IP + port and published via the `onDiscovery` callback
//   → All state changes and errors surface as structured log lines for hardware debugging

import Foundation
import Network
import OSLog

// MARK: - Data Model

struct BridgeEndpoint: Identifiable, Equatable {
    let id = UUID()
    let name: String          // mDNS service instance name (e.g. "Philips Hue - XXXXXX")
    let host: String          // Resolved IPv4 or IPv6 address
    let port: UInt16
}

// MARK: - BridgeDiscoveryService

@MainActor
final class BridgeDiscoveryService: ObservableObject {

    // MARK: Published State
    @Published private(set) var discoveredBridges: [BridgeEndpoint] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var logLines: [String] = []

    // MARK: Private
    private var browser: NWBrowser?
    private let log = Logger(subsystem: "com.lightshade.app", category: "mDNS")
    private let queue = DispatchQueue(label: "com.lightshade.app.mdns", qos: .userInitiated)

    // MARK: mDNS Service Type
    // Philips Hue Bridge advertises itself as _hue._tcp on port 80 / 443.
    private let serviceType = "_hue._tcp"
    private let localDomain = "local."

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    func startScan() {
        guard !isScanning else {
            appendLog("⚠️  Scan already in progress — ignoring duplicate start call.")
            return
        }

        discoveredBridges.removeAll()
        appendLog("🔍 Starting mDNS scan for \(serviceType)…")
        log.info("mDNS: Starting NWBrowser for service type \(self.serviceType, privacy: .public).")
        isScanning = true

        let params = NWParameters()
        params.includePeerToPeer = false   // LAN only; don't surface AirDrop peers

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: localDomain)
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleResults(results, changes: changes)
            }
        }

        newBrowser.start(queue: queue)
        browser = newBrowser
    }

    func stopScan() {
        appendLog("🛑 Stopping mDNS scan.")
        log.info("mDNS: Stopping NWBrowser.")
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Browser State Handler
    // ──────────────────────────────────────────────

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .setup:
            appendLog("ℹ️  NWBrowser → setup")
            log.info("mDNS: Browser state → setup.")

        case .ready:
            appendLog("✅ NWBrowser → ready. Listening for Hue Bridges…")
            log.info("mDNS: Browser state → ready. Actively browning for \(self.serviceType, privacy: .public).")

        case .waiting(let error):
            let msg = "⏳ NWBrowser → waiting: \(error.localizedDescription)"
            appendLog(msg)
            log.warning("mDNS: Browser waiting — \(error.localizedDescription, privacy: .public).")

        case .failed(let error):
            let msg = "❌ NWBrowser → failed: \(error.localizedDescription)"
            appendLog(msg)
            log.error("mDNS: Browser failed — \(error.localizedDescription, privacy: .public).")
            isScanning = false

        case .cancelled:
            appendLog("🚫 NWBrowser → cancelled.")
            log.info("mDNS: Browser cancelled.")
            isScanning = false

        @unknown default:
            appendLog("❓ NWBrowser → unknown state.")
            log.warning("mDNS: Unknown browser state encountered.")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Browse Results Handler
    // ──────────────────────────────────────────────

    private func handleResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                appendLog("📡 Found endpoint: \(endpointDescription(result.endpoint))")
                log.info("mDNS: Endpoint added — \(self.endpointDescription(result.endpoint), privacy: .public).")
                resolveEndpoint(result.endpoint)

            case .removed(let result):
                let desc = endpointDescription(result.endpoint)
                appendLog("💨 Endpoint removed: \(desc)")
                log.info("mDNS: Endpoint removed — \(desc, privacy: .public).")
                // Remove from list if it was already resolved
                discoveredBridges.removeAll { $0.name == serviceName(from: result.endpoint) }

            case .changed(let old, let new, _):
                let desc = endpointDescription(new.endpoint)
                appendLog("♻️  Endpoint changed: \(endpointDescription(old.endpoint)) → \(desc)")
                log.info("mDNS: Endpoint changed — \(desc, privacy: .public).")

            case .identical:
                break  // No-op; re-broadcast with same data

            @unknown default:
                log.warning("mDNS: Unknown browse result change type.")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Endpoint Resolution
    // ──────────────────────────────────────────────

    /// Resolves a Bonjour service endpoint to a concrete host + port via NWConnection.
    /// NWConnection performs the SRV + A/AAAA record lookup internally.
    private func resolveEndpoint(_ endpoint: NWEndpoint) {
        guard case .service(let name, _, _, _) = endpoint else {
            appendLog("⚠️  Cannot resolve non-service endpoint: \(endpointDescription(endpoint))")
            return
        }

        appendLog("🔎 Resolving '\(name)'…")
        log.info("mDNS: Resolving service '\(name, privacy: .public)' via NWConnection.")

        let params = NWParameters.tcp
        // Force IPv4: link-local IPv6 addresses (fe80::…%en0) contain a zone ID that is
        // illegal in RFC-3986 URLs and not supported by URLSession. The Hue Bridge always
        // has an IPv4 address on the same subnet.
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .preparing:
                    // DNS-SD SRV→A lookup is still in flight here.
                    // currentPath?.remoteEndpoint is nil at this stage — do not read it yet.
                    self.appendLog("⏳ Resolving '\(name)' — DNS lookup in flight…")

                case .ready:
                    // ✅ TCP handshake complete — remoteEndpoint is now fully resolved.
                    // Extract IP + port, then immediately cancel (we only needed the address).
                    defer { connection.cancel() }

                    guard let path = connection.currentPath,
                          let remoteEndpoint = path.remoteEndpoint,
                          case .hostPort(let host, let port) = remoteEndpoint else {
                        self.appendLog("⚠️  '\(name)' reached ready but remoteEndpoint was nil — skipping.")
                        self.log.warning("mDNS: remoteEndpoint nil at ready for '\(name, privacy: .public)'.")
                        return
                    }

                    let hostString = self.hostString(from: host)
                    let portValue  = port.rawValue
                    let bridge = BridgeEndpoint(name: name, host: hostString, port: portValue)

                    guard !self.discoveredBridges.contains(where: { $0.host == hostString && $0.port == portValue }) else { return }

                    self.discoveredBridges.append(bridge)
                    let msg = "🌉 Bridge resolved! Name: '\(name)' | IP: \(hostString) | Port: \(portValue)"
                    self.appendLog(msg)
                    self.log.info("mDNS: \(msg, privacy: .public).")

                    // Persist the Bridge IP immediately for later API use.
                    do {
                        try KeychainManager.shared.saveBridgeIP(hostString)
                        self.appendLog("💾 Bridge IP '\(hostString)' saved to Keychain.")
                    } catch {
                        self.appendLog("⚠️  Keychain save failed: \(error.localizedDescription)")
                        self.log.error("mDNS: Keychain save error — \(error.localizedDescription, privacy: .public).")
                    }

                case .failed(let error):
                    self.appendLog("❌ Resolution failed for '\(name)': \(error.localizedDescription)")
                    self.log.error("mDNS: Resolution failed for '\(name, privacy: .public)' — \(error.localizedDescription, privacy: .public).")
                    connection.cancel()

                case .waiting(let error):
                    // This fires if the connection can't reach the host yet (e.g. LAN unreachable).
                    self.appendLog("⏳ Resolution waiting for '\(name)': \(error.localizedDescription)")

                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func endpointDescription(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        case .hostPort(let host, let port):
            return "\(hostString(from: host)):\(port.rawValue)"
        default:
            return endpoint.debugDescription
        }
    }

    private func serviceName(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return ""
    }

    private func hostString(from host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .name(let name, _): raw = name
        case .ipv4(let addr):    raw = addr.debugDescription
        case .ipv6(let addr):    raw = addr.debugDescription
        @unknown default:        raw = host.debugDescription
        }
        // NWFramework appends a zone ID (e.g. %en0) even to IPv4 addresses.
        // Strip it — zone IDs are illegal in URL hostnames and cause URL() to return nil.
        return raw.components(separatedBy: "%").first ?? raw
    }

    @MainActor
    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.logTime.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        logLines.append(line)
        print(line)  // Also surface in Xcode console for hardware debugging
    }
}

// MARK: - DateFormatter Extension

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
