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
        LuminousSheetScaffold(title: "Share Invite",
                              eyebrow: "People",
                              eyebrowSymbol: "qrcode",
                              tint: LuminousPalette.magenta,
                              subtitle: "Let a family member's phone join this home.",
                              ambience: [LuminousPalette.magenta, LuminousPalette.cyan]) {
            explainerCard

            LuminousTitledCard(symbol: "qrcode", title: "Join My Home", tint: LuminousPalette.magenta,
                               glow: LuminousPalette.magenta) {
                VStack(spacing: 16) {
                    if let render {
                        qrBlock(render)
                    } else if let renderError {
                        failureBlock(renderError)
                    } else {
                        ProgressView()
                            .tint(LuminousPalette.magenta)
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
        LuminousNotice(text: "This code carries your bridge's identity — not your keys. The person joining scans it, then presses the button on your Hue Bridge once to pair their own phone. You can also send the link; tapping it does the same thing.",
                       symbol: "person.2.fill", tint: LuminousPalette.cyan)
    }

    private func qrBlock(_ render: Render) -> some View {
        VStack(spacing: 12) {
            Image(uiImage: render.image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 240)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                .shadow(color: LuminousPalette.magenta.opacity(0.45), radius: 22)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR code inviting another phone to join this home")

            Text(render.sharedNames.count == 1
                 ? "Invites to \(render.sharedNames[0])."
                 : "Invites to \(render.sharedNames.joined(separator: ", ")).")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private func failureBlock(_ error: Error) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LuminousPalette.inkTertiary)
            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func linkActions(_ render: Render) -> some View {
        VStack(spacing: 10) {
            ShareLink(
                item: Image(uiImage: render.image),
                subject: Text("Join my home in ChromaGlow"),
                message: Text(render.url.absoluteString),
                preview: SharePreview("ChromaGlow home invite", image: Image(uiImage: render.image))
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .bold))
                    Text("Share QR Image").font(.system(.headline, design: .rounded).weight(.heavy))
                }
                .foregroundStyle(LuminousPalette.void)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LuminousPalette.signalGradient))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: LuminousPalette.cyan.opacity(0.45), radius: 14)
            }

            ShareLink(item: render.url) {
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 15, weight: .semibold))
                    Text("Share Link").font(.system(.subheadline, design: .rounded).weight(.bold))
                }
                .foregroundStyle(LuminousPalette.ink)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .luminousGlass(radius: 18)
            }
        }
        .buttonStyle(LuminousPressStyle(scale: 0.96))
    }

    private var excludedCard: some View {
        LuminousTitledCard(symbol: "exclamationmark.triangle.fill", title: "Not in this invite", tint: LuminousPalette.amber) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(excluded, id: \.id) { record in
                    Text(record.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                }
                Text("These bridges were paired before secure-identity capture existed. Re-pair one in Bridge Manager to make it shareable.")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
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
