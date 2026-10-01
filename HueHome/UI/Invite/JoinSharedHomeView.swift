// JoinSharedHomeView.swift
// ChromaGlow — Share Invite (home-join)
//
// The guest side: a scanned/tapped invite lands here. Each bridge card runs
// the EXISTING pairing flow (BridgeSetupContent) seeded with the invite's
// endpoint — same audited POST, same TOFU identity gate, same registrar —
// plus one extra requirement: the paired bridge's live identity must match
// the invite (`expectedIdentity`). The guest presses the link button once
// per bridge; no credential ever rode the QR.

import SwiftUI

struct JoinSharedHomeView: View {

    let payload: HomeJoinPayload
    /// true = the app is already paired and this join adds bridges
    /// (MainTabView presents it); false = onboarding, this join IS the first
    /// pairing (BridgeSetup presents it).
    var isAddingAdditional: Bool
    /// Called per successfully added bridge in the adding-additional case.
    var onBridgeAdded: ((BridgeRecord) -> Void)? = nil
    /// Called once in the onboarding case after the first bridge pairs.
    var onFirstPairingComplete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var connecting: ConnectTarget?
    @State private var joinedBridgeIDs: Set<String> = []

    private struct ConnectTarget: Identifiable {
        let id: String            // bid
        let join: SharedBridgeJoin
        let vm: BridgeDiscoveryViewModel
    }

    var body: some View {
        LuminousSheetScaffold(title: "Join \(payload.homeName)",
                              eyebrow: "You're invited",
                              eyebrowSymbol: "person.2.fill",
                              tint: LuminousPalette.magenta,
                              subtitle: "Connect this phone to the home you were invited to.",
                              ambience: [LuminousPalette.magenta, LuminousPalette.cyan]) {
            LuminousNotice(text: "Connect to \(payload.bridges.count == 1 ? "the bridge below" : "each bridge below"). You'll press the round button on the Hue Bridge once — that's how Hue grants this phone its own key. The invite carries no passwords.",
                           symbol: "person.2.fill", tint: LuminousPalette.cyan)

            ForEach(payload.bridges, id: \.bid) { bridge in
                bridgeCard(bridge)
            }

            if allJoined {
                doneButton
            }
        }
        .fullScreenCover(item: $connecting) { target in
            seededPairingFlow(target)
        }
        .interactiveDismissDisabled(false)
    }

    private var allJoined: Bool {
        !payload.bridges.isEmpty &&
        payload.bridges.allSatisfy { joinedBridgeIDs.contains($0.bid) }
    }

    // MARK: - Cards

    private func bridgeCard(_ bridge: SharedBridgeJoin) -> some View {
        let joined = joinedBridgeIDs.contains(bridge.bid)
        return LuminousTitledCard(symbol: joined ? "checkmark.seal.fill" : "wifi.router",
                                  title: bridge.name,
                                  subtitle: bridge.host,
                                  tint: joined ? LuminousPalette.live : LuminousPalette.cyan,
                                  glow: joined ? LuminousPalette.live : nil) {
            if joined {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminousPalette.live)
            } else {
                LuminousPrimaryButton(title: "Connect", symbol: "link") {
                    startConnect(bridge)
                }
            }
        }
    }

    private var doneButton: some View {
        LuminousPrimaryButton(title: "All set", symbol: "checkmark", live: true) {
            dismiss()
        }
        .padding(.top, 4)
    }

    // MARK: - Seeded pairing

    private func startConnect(_ bridge: SharedBridgeJoin) {
        let vm = BridgeDiscoveryViewModel()
        // The invite's pin is an EXPECTATION the live TOFU capture must meet —
        // never ingested. Wrong bridge (or tampered QR) → refusal, not trust.
        vm.expectedIdentity = (bridgeID: bridge.bid, publicKeySHA256: bridge.pinPK)
        // Seed the manual-IP seam: straight to the link-button step at the
        // invite's endpoint. "Scan Again" inside the flow still works when
        // DHCP moved the bridge — expectedIdentity keeps it honest.
        vm.phase = .bridgeFound(BridgeEndpoint(
            name: bridge.name,
            host: bridge.host,
            port: UInt16(clamping: bridge.port)
        ))
        connecting = ConnectTarget(id: bridge.bid, join: bridge, vm: vm)
    }

    @ViewBuilder
    private func seededPairingFlow(_ target: ConnectTarget) -> some View {
        ZStack(alignment: .topTrailing) {
            BridgeSetupContent(
                onPaired: {
                    joinedBridgeIDs.insert(target.id)
                    connecting = nil
                    finishIfOnboarding()
                },
                isAddingAdditional: isAddingAdditional,
                onBridgeAdded: { record in
                    joinedBridgeIDs.insert(target.id)
                    connecting = nil
                    onBridgeAdded?(record)
                },
                vm: target.vm
            )
            LuminousRoundButton(symbol: "xmark", label: "Cancel joining") {
                connecting = nil
            }
            .padding(12)
        }
    }

    private func finishIfOnboarding() {
        guard !isAddingAdditional else { return }
        dismiss()
        onFirstPairingComplete?()
    }
}
