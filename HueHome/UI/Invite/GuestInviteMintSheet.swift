// GuestInviteMintSheet.swift
// ChromaGlow — Family Sharing Phase 2 (owner-side per-guest key minting)
//
// The owner mints a DISTINCT application key per bridge for one guest
// profile (devicetype "chromaglow#g-<slug>", generateclientkey:false) by
// pressing the link button once per bridge, then shows a TIME-BOXED,
// DISPLAY-ONLY QR carrying {identity, pin expectation, token, grant}.
//
// This payload is secret-bearing (the token) — the security posture is the
// opposite of ShareInviteSheet's home-join QR:
//   - NO ShareLink anywhere in this file (checklist §7.7),
//   - an on-screen photograph warning,
//   - a visible countdown (expiresAt = now + 15 min),
//   - "New code" re-encodes from the STORED keys with a fresh expiry —
//     no link button, no new bridge whitelist entry.
// The QR/URL value is never logged (SecretLogScrubTests).
//
// Design: docs/ios/profiles-access-share-invite-design-2026-07.md §6.2.

import SwiftUI
import SwiftData

struct GuestInviteMintSheet: View {

    let spec: GuestInviteSpec
    /// Called with ALL of this profile's minted account refs after each
    /// successful mint — the caller (ProfilesAccessView) appends them to
    /// GuestProfile.mintedKeyRefs and stamps lastInviteAt.
    var onMinted: (([String]) -> Void)? = nil

    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @State private var mintStates: [String: MintState] = [:]   // BridgeRecord.id →
    @State private var render: Render?
    @State private var excluded: [BridgeRecord] = []

    private enum MintState: Equatable {
        case idle
        case minting
        case minted
        case failed(String)
    }

    private struct MintTarget: Identifiable {
        let record: BridgeRecord
        let bid: String
        let pinPK: String
        let allowedGroups: [String]
        var id: String { record.id }
    }

    private struct Render {
        let url: URL
        let image: UIImage
        let expiresAt: Date
        let bridgeNames: [String]
    }

    var body: some View {
        StageSheetScaffold(title: "Invite \(spec.profileName)") {
            if spec.isRevoked {
                revokedCard
            } else if spec.allowedGroupIDs.isEmpty {
                noRoomsCard
            } else {
                explainerCard

                ForEach(targets) { target in
                    bridgeCard(target)
                }

                if let render {
                    qrCard(render)
                    warningCard
                }

                if !excluded.isEmpty {
                    excludedCard
                }
            }
        }
        .task { primeStates() }
    }

    // ──────────────────────────────────────────────
    // MARK: - Targets
    // ──────────────────────────────────────────────

    /// Shareable = active, identity captured, pin held (ShareInviteSheet's
    /// criteria) AND the profile allows at least one group on the bridge —
    /// a bridge the guest could see nothing on gets no key at all.
    private var targets: [MintTarget] { computeTargets().targets }

    private func computeTargets() -> (targets: [MintTarget], excluded: [BridgeRecord]) {
        var result: [MintTarget] = []
        var left: [BridgeRecord] = []
        let allowed = Set(spec.allowedGroupIDs)
        for record in bridges where record.isActive {
            guard let bid = record.bridgeIdentifier,
                  let pin = BridgePinStore.shared.pin(forBridgeID: bid) else {
                left.append(record)
                continue
            }
            let bridgeGroups = (orchestrator.allRooms + orchestrator.allZones)
                .filter { $0.bridgeID == record.id }
                .map(\.id)
            let grantable = bridgeGroups.filter { allowed.contains($0) }
            guard !grantable.isEmpty else { continue }
            result.append(MintTarget(record: record, bid: bid,
                                     pinPK: pin.publicKeySHA256,
                                     allowedGroups: grantable.sorted()))
        }
        return (result, left)
    }

    private func primeStates() {
        let computed = computeTargets()
        excluded = computed.excluded
        // A key minted in an earlier session still serves — regeneration
        // reuses it (each RE-mint would add another bridge whitelist entry).
        for target in computed.targets where GuestKeyStore.loadGuestToken(
            profileID: spec.profileID, bridgeRecordID: target.record.id) != nil {
            mintStates[target.record.id] = .minted
        }
        regenerate()
    }

    // ──────────────────────────────────────────────
    // MARK: - Cards
    // ──────────────────────────────────────────────

    private var explainerCard: some View {
        StageCard(icon: "person.badge.key.fill", title: "How this works") {
            Text("Each bridge below issues \(spec.profileName) their own key — press the round button on the bridge, then Mint. The code that appears carries that key: \(spec.profileName) scans it once and is in, no button press needed on their side.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var revokedCard: some View {
        StageCard(icon: "nosign", title: "Access revoked") {
            Text("\(spec.profileName)'s access was revoked, so their invite can't be shown or re-issued. Create a new profile to invite them again.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noRoomsCard: some View {
        StageCard(icon: "square.dashed", title: "No rooms selected") {
            Text("Pick at least one room for \(spec.profileName) before generating their invite — an invite to nothing helps nobody.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bridgeCard(_ target: MintTarget) -> some View {
        let state = mintStates[target.record.id] ?? .idle
        return StageCard(
            icon: state == .minted ? "checkmark.seal.fill" : "wifi.router",
            title: target.record.name,
            subtitle: "\(target.allowedGroups.count) room\(target.allowedGroups.count == 1 ? "" : "s") shared"
        ) {
            VStack(alignment: .leading, spacing: HueSpacing.sm) {
                switch state {
                case .minted:
                    Label("Key issued for \(spec.profileName)", systemImage: "checkmark.circle.fill")
                        .font(HueFont.stageChip)
                        .foregroundStyle(.green)
                case .minting:
                    HStack(spacing: HueSpacing.sm) {
                        ProgressView()
                        Text("Asking the bridge for a key…")
                            .font(HueFont.stageStatus)
                            .foregroundStyle(StagePalette.muted)
                    }
                case .idle, .failed:
                    if case .failed(let message) = state {
                        Text(message)
                            .font(HueFont.stageStatus)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Press the round button on \(target.record.name), then tap Mint.")
                            .font(HueFont.stageStatus)
                            .foregroundStyle(StagePalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        mint(target)
                    } label: {
                        Label("Mint Key", systemImage: "key.fill")
                            .font(HueFont.stageChip)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: HueRadius.lg)
                                    .fill(HuePalette.amber.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .tint(HuePalette.amber)
                }
            }
        }
    }

    private func qrCard(_ render: Render) -> some View {
        StageCard(icon: "qrcode", title: "Show this to \(spec.profileName)") {
            VStack(spacing: HueSpacing.sm) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = render.expiresAt.timeIntervalSince(context.date)
                    VStack(spacing: HueSpacing.sm) {
                        Image(uiImage: render.image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .padding(HueSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous)
                                    .fill(.white)
                            )
                            .opacity(remaining > 0 ? 1 : 0.25)
                            .accessibilityLabel("Guest invite QR code for \(spec.profileName)")

                        if remaining > 0 {
                            Text("Code expires in \(Self.countdown(remaining))")
                                .font(HueFont.stageChip)
                                .foregroundStyle(HuePalette.amber)
                                .monospacedDigit()
                        } else {
                            Text("Code expired — generate a new one.")
                                .font(HueFont.stageChip)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Text(render.bridgeNames.count == 1
                     ? "Grants access on \(render.bridgeNames[0])."
                     : "Grants access on \(render.bridgeNames.joined(separator: ", ")).")
                    .font(HueFont.stageStatus)
                    .foregroundStyle(StagePalette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    regenerate()
                } label: {
                    Label("New Code", systemImage: "arrow.clockwise")
                        .font(HueFont.stageChip)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: HueRadius.lg)
                                .fill(Color.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .tint(.white)
            }
        }
    }

    private var warningCard: some View {
        StageCard(icon: "exclamationmark.triangle.fill", title: "This code IS the key") {
            Text("Show it directly to \(spec.profileName) — anyone who photographs it can control the shared rooms' bridges until you revoke access. The countdown limits how long the code can be redeemed; the key itself keeps working after it.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var excludedCard: some View {
        StageCard(icon: "exclamationmark.triangle", title: "Not in this invite") {
            VStack(alignment: .leading, spacing: HueSpacing.xs) {
                ForEach(excluded, id: \.id) { record in
                    Text(record.name)
                        .font(HueFont.stageControl)
                        .foregroundStyle(StagePalette.ink)
                }
                Text("These bridges were paired before secure-identity capture existed. Re-pair one in Bridge Manager to make it shareable.")
                    .font(HueFont.stageStatus)
                    .foregroundStyle(StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Mint + QR
    // ──────────────────────────────────────────────

    private func mint(_ target: MintTarget) {
        mintStates[target.record.id] = .minting
        Task {
            // Log lines are H-04-clean (counts only), but the mint sheet has
            // no debug console — drop them.
            let minter = ApplicationKeyMinter(appendLog: { _ in })
            let segment = ApplicationKeyMinter.guestDeviceSegment(
                profileName: spec.profileName, profileID: spec.profileID
            )
            let result = await minter.mint(
                endpoint: BridgeEndpoint(
                    name: target.record.name,
                    host: target.record.host,
                    port: UInt16(clamping: target.record.port)
                ),
                devicetype: AppBrand.guestHueDeviceType(deviceSegment: segment),
                generateClientKey: false,   // guests never receive a clientkey (§7.3)
                expectedIdentity: (bridgeID: target.bid, publicKeySHA256: target.pinPK)
            )

            switch result {
            case .success(let minted):
                do {
                    try GuestKeyStore.saveGuestToken(
                        minted.token,
                        profileID: spec.profileID,
                        bridgeRecordID: target.record.id
                    )
                    mintStates[target.record.id] = .minted
                    notifyMintedRefs()
                    regenerate()
                } catch {
                    mintStates[target.record.id] =
                        .failed("The key couldn't be stored: \(error.localizedDescription)")
                }
            case .failure(.bridgeRefused(101, _)):
                mintStates[target.record.id] =
                    .failed("Link button not pressed. Press the round button on \(target.record.name), then tap Mint again.")
            case .failure(.expectedIdentityMismatch):
                mintStates[target.record.id] =
                    .failed("The bridge answering at \(target.record.host) isn't \(target.record.name). Check your network, then try again.")
            case .failure(.identityVerificationFailed):
                mintStates[target.record.id] =
                    .failed("Couldn't verify \(target.record.name)'s secure identity. Make sure you're on the same network, then try again.")
            case .failure:
                mintStates[target.record.id] =
                    .failed("Couldn't reach \(target.record.name). Check Wi-Fi and try again.")
            }
        }
    }

    private func notifyMintedRefs() {
        let refs = targets.compactMap { target -> String? in
            guard GuestKeyStore.loadGuestToken(
                profileID: spec.profileID, bridgeRecordID: target.record.id) != nil else { return nil }
            return GuestKeyStore.account(profileID: spec.profileID, bridgeRecordID: target.record.id)
        }
        onMinted?(refs)
    }

    /// Re-encode the QR from the STORED keys with a fresh expiry — no link
    /// button, no re-mint, no new whitelist entry.
    private func regenerate() {
        let expiresAt = Date().addingTimeInterval(InvitePayloadCodec.inviteTTL)
        let grants = targets.compactMap { target -> SharedBridgeInviteGrant? in
            guard let token = GuestKeyStore.loadGuestToken(
                profileID: spec.profileID, bridgeRecordID: target.record.id) else { return nil }
            return SharedBridgeInviteGrant(
                bid: target.bid,
                host: target.record.host,
                port: target.record.port,
                name: target.record.name,
                pinPK: target.pinPK,
                token: token,
                allowedGroups: target.allowedGroups,
                features: spec.features,
                expiresAt: expiresAt
            )
        }
        guard !grants.isEmpty else {
            render = nil
            return
        }
        do {
            let payload = GuestInvitePayload(
                bridges: grants,
                homeName: "My Home",
                profileName: spec.profileName,
                issuedAt: Date()
            )
            let url = try InvitePayloadCodec.encodeInvite(payload)
            let image = try SceneQRRenderer.render(url)
            render = Render(url: url, image: image, expiresAt: expiresAt,
                            bridgeNames: grants.map(\.name))
        } catch {
            render = nil
        }
    }

    private static func countdown(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
