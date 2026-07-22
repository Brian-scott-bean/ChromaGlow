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

    /// Validates a user-typed bridge address before it may enter the pairing
    /// flow (audit L-16): a strict IPv4 literal (out-of-range and
    /// leading-zero octets rejected), an IPv6 literal, or an
    /// RFC-1123 hostname (covers `philips-hue.local`). Returns the trimmed
    /// host, or nil. Deliberately no private-range requirement — VPN/CGNAT
    /// homes (100.64/10) legitimately reach bridges outside RFC1918; the
    /// pairing TOFU identity gate remains the real protection.
    static func validatedManualHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253 else { return nil }

        // Darwin's inet_pton is BSD-lenient about leading-zero octets
        // ("01.2.3.4" parses) — reject them ourselves before consulting it.
        let dotLabels = host.split(separator: ".", omittingEmptySubsequences: false)
        if dotLabels.count == 4, dotLabels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            guard dotLabels.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return host }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return host }

        // RFC-1123 hostname: dot-separated labels, 1–63 chars of
        // [A-Za-z0-9-], no leading/trailing hyphen, no empty labels.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard (1...63).contains(label.count),
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
        }
        // All-numeric labels are a malformed IPv4 (192.168.1.999), not a
        // DNS name — refuse rather than hand a typo to the pairing flow.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }
        return host
    }
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
            log.warning("mDNS: Browser waiting — \(error.localizedDescription).")

        case .failed(let error):
            let msg = "❌ NWBrowser → failed: \(error.localizedDescription)"
            appendLog(msg)
            log.error("mDNS: Browser failed — \(error.localizedDescription).")
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
                log.info("mDNS: Endpoint added — \(self.endpointDescription(result.endpoint)).")
                resolveEndpoint(result.endpoint)

            case .removed(let result):
                let desc = endpointDescription(result.endpoint)
                appendLog("💨 Endpoint removed: \(desc)")
                log.info("mDNS: Endpoint removed — \(desc).")
                // Remove from list if it was already resolved
                discoveredBridges.removeAll { $0.name == serviceName(from: result.endpoint) }

            case .changed(let old, let new, _):
                let desc = endpointDescription(new.endpoint)
                appendLog("♻️  Endpoint changed: \(endpointDescription(old.endpoint)) → \(desc)")
                log.info("mDNS: Endpoint changed — \(desc).")

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
        log.info("mDNS: Resolving service '\(name)' via NWConnection.")

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
                        self.log.warning("mDNS: remoteEndpoint nil at ready for '\(name)'.")
                        return
                    }

                    let hostString = self.hostString(from: host)
                    let portValue  = port.rawValue
                    let bridge = BridgeEndpoint(name: name, host: hostString, port: portValue)

                    guard !self.discoveredBridges.contains(where: { $0.host == hostString && $0.port == portValue }) else { return }

                    self.discoveredBridges.append(bridge)
                    let msg = "🌉 Bridge resolved! Name: '\(name)' | IP: \(hostString) | Port: \(portValue)"
                    self.appendLog(msg)
                    self.log.info("mDNS: \(msg).")
                    // NOTE: no Keychain write here. This used to save the legacy
                    // `hue_bridge_ip` slot per resolved endpoint (SecItemDelete+Add on
                    // the main actor, per bridge, per scan round) — but modern pairing
                    // writes namespaced per-bridge slots and every legacy consumer also
                    // requires the legacy token, which discovery never writes. Pure waste.

                case .failed(let error):
                    self.appendLog("❌ Resolution failed for '\(name)': \(error.localizedDescription)")
                    self.log.error("mDNS: Resolution failed for '\(name)' — \(error.localizedDescription).")
                    connection.cancel()

                case .waiting(let error):
                    // This fires if the connection can't reach the host yet (e.g. LAN unreachable).
                    // On a fresh install this is also the Local Network permission-denial
                    // signature (mDNS resolves, TCP to the LAN IP is blocked until Allow).
                    StartupTimeline.mark("discovery.resolve-waiting", "'\(name)' \(error.localizedDescription)")
                    self.appendLog("⏳ Resolution waiting for '\(name)': \(error.localizedDescription)")

                default:
                    break
                }
            }
        }

        connection.start(queue: queue)

        // Bounded resolution: an mDNS-advertised but unreachable endpoint used to
        // leave this NWConnection dangling in .waiting/.preparing forever (only
        // .ready and .failed cancel it above). 10s is generous for a LAN SRV→A
        // lookup + TCP handshake; a cancelled attempt just drops this endpoint.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let connection else { return }
            switch connection.state {
            case .ready, .cancelled, .failed:
                break   // already settled — handler above did/does the cleanup
            default:
                self?.log.warning("mDNS: Resolution timeout for '\(name)' after 10s — cancelling.")
                connection.cancel()
            }
        }
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
#if DEBUG
        print(line)  // Also surface in Xcode console for hardware debugging
#endif
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
