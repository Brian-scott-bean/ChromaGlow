// GuestInviteAcceptView.swift
// ChromaGlow — Family Sharing Phase 2 (guest side, token-bearing invite)
//
// The guest's mirror of JoinSharedHomeView, minus the link button: the
// invite carries a key minted just for this person, so each bridge card
// is a one-tap Connect that runs GuestInviteAcceptor's identity-gated
// accept. On success the grant is committed BEFORE the bridge integrates
// (upsert → updateGuestGrants → addBridge → loadAll) so the very first
// paint of the new bridge is already room-filtered.

import SwiftUI
import SwiftData

struct GuestInviteAcceptView: View {

    let payload: GuestInvitePayload
    /// true = already paired, MainTabView presents this to add bridges;
    /// false = onboarding, BridgeSetup presents it as the first pairing.
    var isAddingAdditional: Bool
    var onBridgeAdded: ((BridgeRecord) -> Void)? = nil
    var onFirstPairingComplete: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var states: [String: JoinState] = [:]   // bid →

    private enum JoinState: Equatable {
        case idle
        case connecting
        case joined
        case failed(String)   // user-facing copy per outcome
    }

    var body: some View {
        LuminousSheetScaffold(title: "Join \(payload.homeName)",
                              eyebrow: "You're invited",
                              eyebrowSymbol: "person.badge.key.fill",
                              tint: LuminousPalette.magenta,
                              subtitle: "A key was made just for you — no button to press.",
                              ambience: [LuminousPalette.magenta, LuminousPalette.cyan]) {
            if payload.isExpired() {
                expiredCard
            } else {
                introCard

                ForEach(payload.bridges, id: \.bid) { grant in
                    bridgeCard(grant)
                }

                if allJoined {
                    doneButton
                }

                limitsFootnote
            }
        }
        .interactiveDismissDisabled(false)
    }

    private var allJoined: Bool {
        !payload.bridges.isEmpty &&
        payload.bridges.allSatisfy { states[$0.bid] == .joined }
    }

    // ──────────────────────────────────────────────
    // MARK: - Cards
    // ──────────────────────────────────────────────

    private var introCard: some View {
        LuminousNotice(text: "You're in as \"\(payload.profileName)\". No button press needed — this invite carries a key minted just for you. Tap Connect on each bridge below.",
                       symbol: "person.badge.key.fill", tint: LuminousPalette.cyan)
    }

    private var expiredCard: some View {
        LuminousEmptyState(symbol: "clock.badge.exclamationmark", title: "This code has expired",
                           message: "Invite codes stop working after a short window. Ask the person who invited you to open the invite again and show you a fresh code — your access doesn't change, only the code does.")
    }

    private func bridgeCard(_ grant: SharedBridgeInviteGrant) -> some View {
        let state = states[grant.bid] ?? .idle
        let joined = state == .joined
        return LuminousTitledCard(
            symbol: joined ? "checkmark.seal.fill" : "wifi.router",
            title: grant.name,
            subtitle: "\(grant.allowedGroups.count) room\(grant.allowedGroups.count == 1 ? "" : "s") shared with you",
            tint: joined ? LuminousPalette.live : LuminousPalette.cyan,
            glow: joined ? LuminousPalette.live : nil
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch state {
                case .joined:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LuminousPalette.live)
                case .connecting:
                    HStack(spacing: 10) {
                        ProgressView().tint(LuminousPalette.cyan)
                        Text("Verifying the bridge and your key…")
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                case .idle, .failed:
                    if case .failed(let message) = state {
                        Text(message)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LuminousPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LuminousPrimaryButton(title: "Connect", symbol: "link") {
                        connect(grant)
                    }
                }
            }
        }
    }

    private var doneButton: some View {
        LuminousPrimaryButton(title: "All set", symbol: "checkmark", live: true) {
            dismiss()
            if !isAddingAdditional { onFirstPairingComplete?() }
        }
        .padding(.top, 4)
    }

    private var limitsFootnote: some View {
        LuminousTitledCard(symbol: "info.circle", title: "About your access", tint: LuminousPalette.inkSecondary) {
            Text("Room limits apply inside ChromaGlow on this phone. The key itself can control the whole bridge from any Hue app — a Philips Hue limitation. To change what you can access, ask the owner for a new invite and scan it again.")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Accept
    // ──────────────────────────────────────────────

    private func connect(_ grant: SharedBridgeInviteGrant) {
        states[grant.bid] = .connecting
        Task {
            let acceptor = GuestInviteAcceptor()
            // Ordering contract: grant BEFORE addBridge/loadAll, so the
            // first rebuild after integration is already filtered.
            acceptor.onGrantEstablished = { seed in
                // `try`, not `try?`: a grant that fails to save must fail the
                // join (the acceptor then removes the key) — swallowing it
                // left a guest key with NO restrictions at all.
                try GuestAccessGrantStore.upsert(
                    bridgeRecordID: seed.bridgeRecordID,
                    allowedGroupIDs: seed.allowedGroupIDs,
                    features: seed.features,
                    grantedProfileName: seed.grantedProfileName,
                    receivedAt: seed.receivedAt,
                    modelContext: modelContext
                )
                orchestrator.updateGuestGrants(from: modelContext)
            }

            let outcome = await acceptor.accept(
                grant: grant,
                profileName: payload.profileName,
                modelContext: modelContext
            )

            switch outcome {
            case .joined(let recordID):
                states[grant.bid] = .joined
                if isAddingAdditional,
                   let record = fetchRecord(id: recordID) {
                    onBridgeAdded?(record)
                }
            case .expired:
                states[grant.bid] = .failed(
                    "This code has expired — ask for a fresh one. (Your access doesn't change, only the code.)")
            case .revokedBeforeAccept:
                states[grant.bid] = .failed(
                    "This invite has already been revoked — ask the owner for a new one.")
            case .bridgeUnreachable:
                states[grant.bid] = .failed(
                    "Couldn't reach \(grant.name). Make sure you're on the home's Wi-Fi, then try again.")
            case .identityMismatch:
                states[grant.bid] = .failed(
                    "The bridge answering here doesn't match the invite. Make sure you're on the inviter's Wi-Fi and scanning their current code.")
            case .alreadyConnected:
                states[grant.bid] = .joined
            case .persistFailed(let message):
                states[grant.bid] = .failed("Couldn't save the connection: \(message)")
            }
        }
    }

    private func fetchRecord(id: String) -> BridgeRecord? {
        // Fetch-all + filter: a handful of records, and #Predicate trips the
        // KeyPath-Sendable strict-concurrency warning on this toolchain.
        ((try? modelContext.fetch(FetchDescriptor<BridgeRecord>())) ?? [])
            .first { $0.id == id }
    }
}
