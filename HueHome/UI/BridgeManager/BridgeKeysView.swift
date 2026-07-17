// BridgeKeysView.swift
// ChromaGlow — Family Sharing Phase 4 ("Keys on this bridge")
//
// The revocation design's hardware spike, shipped as a runtime probe:
// whether modern Hue firmware still exposes the v1 whitelist locally is
// answered HERE, on the owner's real bridge, with first-class UI for
// both outcomes. Keys are other apps' secrets (H-03) — rows render the
// truncated displayID only; the full element exists solely to issue the
// DELETE.
//
// "Try Remove" = best-effort DELETE verified by re-read. The dialogs are
// honest in both firmware worlds (design §4): a verified delete says so;
// anything else states that real revocation lives in official Hue tooling.

import SwiftUI
import SwiftData

struct BridgeKeysView: View {

    let bridge: BridgeRecord

    @State private var loadState: LoadState = .loading
    @State private var removingElement: String?
    @State private var outcomeMessage: String?

    private enum LoadState {
        case loading
        case unsupported
        case loaded([HueV1Client.WhitelistEntry])
        case failed(String)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#141224"), Color(hex: "#0B0A14")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    switch loadState {
                    case .loading:
                        ProgressView("Asking \(bridge.name) for its key list…")
                            .tint(.white)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 60)

                    case .unsupported:
                        unsupportedCard

                    case .failed(let message):
                        StageCard(icon: "wifi.exclamationmark", title: "Couldn't read the bridge") {
                            Text(message)
                                .font(HueFont.stageStatus)
                                .foregroundStyle(StagePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                    case .loaded(let entries):
                        StageCard(icon: "key.fill", title: "\(entries.count) keys on \(bridge.name)") {
                            Text("Every app ever paired with this bridge holds one. Yours are named chromaglow; a guest's reads chromaglow#g-….")
                                .font(HueFont.stageStatus)
                                .foregroundStyle(StagePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(entries) { entry in
                            keyRow(entry)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Keys on this Bridge")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await load() }
        .alert("Key Removal", isPresented: Binding(
            get: { outcomeMessage != nil },
            set: { if !$0 { outcomeMessage = nil } }
        )) {
            Button("OK", role: .cancel) { outcomeMessage = nil }
        } message: {
            Text(outcomeMessage ?? "")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Cards
    // ──────────────────────────────────────────────

    private var unsupportedCard: some View {
        StageCard(icon: "lock.shield", title: "Not available on this bridge") {
            Text("This bridge's software doesn't share its key list locally. Keys can be viewed and revoked from the official Philips Hue app (or by resetting app keys on the bridge).")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyRow(_ entry: HueV1Client.WhitelistEntry) -> some View {
        StageCard(icon: "key.horizontal", title: entry.name) {
            VStack(alignment: .leading, spacing: HueSpacing.sm) {
                HStack(spacing: 10) {
                    Text(entry.displayID)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(StagePalette.muted)
                    if let lastUse = entry.lastUseDate {
                        Text("· last used \(lastUse)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Spacer()
                }

                Button {
                    Task { await tryRemove(entry) }
                } label: {
                    if removingElement == entry.element {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    } else {
                        Label("Try Remove", systemImage: "trash")
                            .font(HueFont.stageChip)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: HueRadius.lg)
                                    .fill(Color.red.opacity(0.12))
                            )
                    }
                }
                .buttonStyle(.plain)
                .tint(.red)
                .disabled(removingElement != nil)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Bridge I/O
    // ──────────────────────────────────────────────

    private func makeClient() -> HueV1Client? {
        guard let creds = try? KeychainManager.shared.loadCredentials(for: bridge.id) else {
            return nil
        }
        return HueV1Client(ip: creds.ip, token: creds.token)
    }

    private func load() async {
        guard let client = makeClient() else {
            loadState = .failed("No credentials for this bridge on this phone.")
            return
        }
        do {
            if let entries = try await client.fetchWhitelist() {
                loadState = .loaded(entries)
            } else {
                loadState = .unsupported
            }
        } catch {
            loadState = .failed("The bridge didn't answer. Make sure you're on the same network, then try again.")
        }
    }

    private func tryRemove(_ entry: HueV1Client.WhitelistEntry) async {
        guard let client = makeClient() else { return }
        removingElement = entry.element
        defer { removingElement = nil }
        do {
            switch try await client.deleteWhitelistEntry(element: entry.element) {
            case .deletedVerified:
                outcomeMessage = "The key was deleted from the bridge itself — whoever held it is fully signed out."
            case .unsupportedByFirmware, .stillPresent:
                outcomeMessage = "This bridge refused the removal. Removing a guest in ChromaGlow deletes their key from this phone and blocks re-inviting. Their existing bridge access can only be fully revoked from the official Philips Hue app (or by resetting app keys)."
            }
            await load()
        } catch {
            outcomeMessage = "The bridge didn't answer — nothing changed. Check the network and try again."
        }
    }
}
