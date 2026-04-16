// BridgeSetupView.swift
// HueHome Pro — Epic 1 / Story 1.1 (rev 2)
//
// Phase-driven UI matching the DiscoveryPhase state machine:
//   idle         → "Scan for Bridge" button
//   scanning     → spinner + live mDNS console
//   bridgeFound  → bridge info card + "Pair" button (press physical button first)
//   pairing      → progress indicator + console
//   paired       → success summary
//   error        → error message + retry

import SwiftUI

struct BridgeSetupView: View {

    /// Called by parent (AppRootView via SplashView) after successful pairing.
    var onPaired: (() -> Void)? = nil

    @State private var vm = BridgeDiscoveryViewModel()
    @State private var navigateToDashboard = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                phaseCard
                    .padding([.horizontal, .top])

                Divider()
                    .padding(.vertical, 8)

                consoleLog
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("HueHome Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if case .paired = vm.phase { } else {
                        Button("Reset") { vm.resetToIdle() }
                            .font(.caption)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToDashboard) {
                DashboardView()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Phase Card
    // ──────────────────────────────────────────────

    @ViewBuilder
    private var phaseCard: some View {
        switch vm.phase {

        case .idle:
            idleView

        case .scanning:
            scanningView

        case .bridgeFound(let bridge):
            bridgeFoundView(bridge: bridge)

        case .pairing(let bridge):
            pairingView(bridge: bridge)

        case .paired(let ip, let token):
            pairedView(ip: ip, token: token)

        case .error(let msg):
            errorView(message: msg)
        }
    }

    // ── Idle ─────────────────────────────────────
    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.circle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Find Your Hue Bridge")
                .font(.headline)

            Text("Make sure your iPhone and the Hue Bridge are on the same Wi-Fi network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                vm.startScan()
            } label: {
                Label("Scan for Bridge", systemImage: "magnifyingglass.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // ── Scanning ──────────────────────────────────
    private var scanningView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Scanning for Hue Bridge…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Searching for _hue._tcp on your local Wi-Fi.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // ── Bridge Found ──────────────────────────────
    private func bridgeFoundView(bridge: BridgeEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bridge Discovered!", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                infoRow(label: "Name", value: bridge.name)
                infoRow(label: "IP",   value: bridge.host)
                infoRow(label: "Port", value: "\(bridge.port)")
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Label("Next step:", systemImage: "hand.point.up.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Press the **round link button** on the top of your Hue Bridge, then tap Pair below. You have ~30 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                vm.pairWithBridge(bridge)
            } label: {
                Label("Pair with Bridge", systemImage: "link.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Pairing In-Flight ─────────────────────────
    private func pairingView(bridge: BridgeEndpoint) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Pairing with \(bridge.name)…")
                    .font(.subheadline)
            }
            Text("Sending POST to http://\(bridge.host)/api")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // ── Paired ────────────────────────────────────
    private func pairedView(ip: String, token: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Paired Successfully!", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                infoRow(label: "Bridge IP", value: ip)
                infoRow(label: "Token",     value: String(token.prefix(12)) + "…")
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Both values are saved to Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                // If we have a callback (new flow), call it.
                // Otherwise fall back to internal navigation (legacy).
                if let onPaired {
                    onPaired()
                } else {
                    navigateToDashboard = true
                }
            } label: {
                Label("Go to Dashboard", systemImage: "lightbulb.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Error ─────────────────────────────────────
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                vm.resetToIdle()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Console Log
    // ──────────────────────────────────────────────

    @ViewBuilder
    private var consoleLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("mDNS / Pairing Console")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(vm.logLines.count) events")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)
                .onChange(of: vm.logLines.count) { _, newCount in
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}
