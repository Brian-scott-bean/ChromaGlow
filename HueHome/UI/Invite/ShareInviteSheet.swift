// ShareInviteSheet.swift
// ChromaGlow — Share Invite (home-join)
//
// The owner side: one QR that lets a family member's phone join this home.
// The QR carries bridge IDENTITY (bridgeid, last-known host, expected TLS
// pin) — never a key. The person joining pairs with the bridge themselves by
// pressing its link button once, so nothing here is secret and ShareLink is
// allowed (unlike a future token-bearing invite, which must be display-only).

import SwiftUI
import SwiftData

struct ShareInviteSheet: View {

    @Query(sort: \BridgeRecord.sortOrder) private var bridges: [BridgeRecord]

    @State private var render: Render?
    @State private var renderError: Error?
    @State private var excluded: [BridgeRecord] = []

    private struct Render {
        let url: URL
        let image: UIImage
        let isDense: Bool
        let sharedNames: [String]
    }

    private struct NoShareableBridge: LocalizedError {
        var errorDescription: String? {
            "No shareable bridge yet. A bridge becomes shareable after it has been paired on this phone with its secure identity verified — try removing and re-pairing it in Bridge Manager."
        }
    }

    var body: some View {
        StageSheetScaffold(title: "Share Invite") {
            explainerCard

            StageCard(icon: "qrcode", title: "Join My Home") {
                VStack(spacing: HueSpacing.lg) {
                    if let render {
                        qrBlock(render)
                    } else if let renderError {
                        failureBlock(renderError)
                    } else {
                        ProgressView()
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            if let render {
                linkActions(render)
            }

            if !excluded.isEmpty {
                excludedCard
            }
        }
        .task {
            guard render == nil, renderError == nil else { return }
            do { render = try makeRender() }
            catch { renderError = error }
        }
    }

    // MARK: - Blocks

    private var explainerCard: some View {
        StageCard(icon: "person.2.fill", title: "How it works") {
            Text("This code carries your bridge's identity — not your keys. The person joining scans it, then presses the button on your Hue Bridge once to pair their own phone. You can also send the link; tapping it does the same thing.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func qrBlock(_ render: Render) -> some View {
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
                .accessibilityLabel("QR code inviting another phone to join this home")

            Text(render.sharedNames.count == 1
                 ? "Invites to \(render.sharedNames[0])."
                 : "Invites to \(render.sharedNames.joined(separator: ", ")).")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureBlock(_ error: Error) -> some View {
        VStack(spacing: HueSpacing.sm) {
            Image(systemName: "qrcode")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(StagePalette.muted)

            Text(error.localizedDescription)
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HueSpacing.lg)
    }

    private func linkActions(_ render: Render) -> some View {
        VStack(spacing: HueSpacing.sm) {
            ShareLink(
                item: Image(uiImage: render.image),
                subject: Text("Join my home in ChromaGlow"),
                message: Text(render.url.absoluteString),
                preview: SharePreview("ChromaGlow home invite", image: Image(uiImage: render.image))
            ) {
                Label("Share QR Image", systemImage: "square.and.arrow.up")
                    .font(HueFont.stageChip)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: HueRadius.lg)
                            .fill(HuePalette.amber.opacity(0.15))
                    )
            }
            .tint(HuePalette.amber)

            ShareLink(item: render.url) {
                Label("Share Link", systemImage: "link")
                    .font(HueFont.stageChip)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: HueRadius.lg)
                            .fill(Color.white.opacity(0.07))
                    )
            }
            .tint(.white)
        }
        .buttonStyle(.plain)
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

    // MARK: - Render

    private func makeRender() throws -> Render {
        var shareable: [SharedBridgeJoin] = []
        var left: [BridgeRecord] = []
        for record in bridges where record.isActive {
            // Shareable = we know the bridge's canonical identity AND hold a
            // verified pin to hand the guest as its trust expectation.
            guard let bid = record.bridgeIdentifier,
                  let pin = BridgePinStore.shared.pin(forBridgeID: bid) else {
                left.append(record)
                continue
            }
            shareable.append(SharedBridgeJoin(
                bid: bid,
                host: record.host,
                port: record.port,
                name: record.name,
                pinPK: pin.publicKeySHA256
            ))
        }
        excluded = left
        guard !shareable.isEmpty else { throw NoShareableBridge() }

        let payload = HomeJoinPayload(
            bridges: shareable,
            homeName: "My Home",
            issuedAt: Date()
        )
        let url = try InvitePayloadCodec.encode(payload)
        let image = try SceneQRRenderer.render(url)
        return Render(url: url, image: image,
                      isDense: SceneQRRenderer.isDense(url),
                      sharedNames: shareable.map(\.name))
    }
}
