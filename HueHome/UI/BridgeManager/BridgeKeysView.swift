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

    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @State private var loadState: LoadState = .loading
    @State private var removingElement: String?
    @State private var outcomeMessage: String?
    /// Key awaiting the "Remove this key?" confirmation.
    @State private var pendingRemoval: HueV1Client.WhitelistEntry?

    /// A guest-held (granted) bridge belongs to someone else: its key list
    /// is shown for honesty, but removal is never offered from this phone.
    private var isGuestBridge: Bool { orchestrator.isGuestGrantedBridge(bridge.id) }

    /// This phone's own key on the bridge (read once in `load()`). Removing
    /// it would sign this app out of the bridge with no warning — never
    /// offered. Compared only; never logged or rendered (H-03).
    @State private var ownKey: String?

    private enum LoadState {
        case loading
        case unsupported
        case loaded([HueV1Client.WhitelistEntry])
        case failed(String)
    }

    var body: some View {
        LuminousPage(title: "Keys on this Bridge",
                     eyebrow: bridge.name,
                     eyebrowSymbol: "key.fill",
                     tint: LuminousPalette.amber,
                     subtitle: "Every app ever paired with this bridge holds one.",
                     ambience: [LuminousPalette.amber, LuminousPalette.violet]) {
            switch loadState {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView().tint(LuminousPalette.amber)
                    Text("Asking \(bridge.name) for its key list…")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .luminousGlass()

            case .unsupported:
                unsupportedCard

            case .failed(let message):
                LuminousEmptyState(symbol: "wifi.exclamationmark", title: "Couldn't read the bridge", message: message)

            case .loaded(let entries):
                LuminousNotice(text: "\(entries.count) keys on \(bridge.name). Yours are named chromaglow; a guest's reads chromaglow#g-….",
                               symbol: "key.fill", tint: LuminousPalette.amber)
                LuminousGroup {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        keyRow(entry)
                        if idx < entries.count - 1 { LuminousRowDivider() }
                    }
                }
            }
        }
        .task { await load() }
        .alert("Key Removal", isPresented: Binding(
            get: { outcomeMessage != nil },
            set: { if !$0 { outcomeMessage = nil } }
        )) {
            Button("OK", role: .cancel) { outcomeMessage = nil }
        } message: {
            Text(outcomeMessage ?? "")
        }
        .alert("Remove this key?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { entry in
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task { await tryRemove(entry) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { entry in
            Text("\"\(entry.name)\" will be signed out of \(bridge.name). Whatever app or phone holds this key loses access until it pairs again.")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Cards
    // ──────────────────────────────────────────────

    private var unsupportedCard: some View {
        LuminousEmptyState(symbol: "lock.shield",
                           title: "Not available on this bridge",
                           message: "This bridge's software doesn't share its key list locally. Keys can be viewed and revoked from the official Philips Hue app (or by resetting app keys on the bridge).")
    }

    /// One key. Only the truncated id is ever shown (H-03); this phone's own
    /// key and a guest-held bridge's keys are never offered for removal.
    private func keyRow(_ entry: HueV1Client.WhitelistEntry) -> some View {
        let isOwn = entry.element == ownKey
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                LuminousIconBadge(symbol: "key.horizontal.fill",
                                  tint: isOwn ? LuminousPalette.cyan : LuminousPalette.amber, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(entry.displayID)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                        if let lastUse = entry.lastUseDate {
                            Text("· last used \(lastUse)")
                                .font(.caption)
                                .foregroundStyle(LuminousPalette.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                if isOwn {
                    LuminousTextBadge(text: "This phone", tint: LuminousPalette.cyan)
                }
            }

            if isOwn {
                Text("This phone's key — remove the bridge in Bridge Manager instead.")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isGuestBridge {
                Text("Shared with you — only the bridge's owner can remove keys.")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    pendingRemoval = entry   // confirm first — this is destructive
                } label: {
                    HStack(spacing: 8) {
                        if removingElement == entry.element {
                            ProgressView().tint(LuminousPalette.danger)
                        } else {
                            Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                            Text("Try Remove").font(.system(.subheadline, design: .rounded).weight(.bold))
                        }
                    }
                    .foregroundStyle(LuminousPalette.danger)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LuminousPalette.danger.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LuminousPalette.danger.opacity(0.3), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(LuminousPressStyle())
                .disabled(removingElement != nil)
                .accessibilityLabel("Try to remove \(entry.name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
        ownKey = (try? KeychainManager.shared.loadCredentials(for: bridge.id))?.token
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
        // Backstops for the row gating above.
        guard !isGuestBridge, entry.element != ownKey,
              let client = makeClient() else { return }
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
