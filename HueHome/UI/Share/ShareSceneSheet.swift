// ShareSceneSheet.swift
// ChromaGlow — scene sharing
//
// Shows a scene as a QR code plus a copyable link. There is no upload step and
// no account: the QR *is* the scene, so it works across the room, across a
// text message, or printed on paper — and it keeps working when ChromaGlow's
// servers (which do not exist) are down.
//
// When a scene is too detailed to fit in a QR the sheet says so plainly and
// still offers the link, which carries the whole scene regardless.

import SwiftUI

struct ShareSceneSheet: View {

    let preset: CompositionPreset

    @Environment(\.dismiss) private var dismiss

    /// Rendered once, off the first render pass — QR generation is CoreImage
    /// work and does not belong in `body`.
    @State private var render: Render?
    @State private var renderError: Error?

    private struct Render {
        let url: URL
        let image: UIImage
        let isDense: Bool
    }

    var body: some View {
        StageSheetScaffold(title: "Share \(preset.name)") {
            StageCard(icon: preset.icon, title: preset.name) {
                VStack(spacing: HueSpacing.lg) {
                    ScenePaletteRibbon(palette: preset.palette)

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
        }
        .task {
            guard render == nil, renderError == nil else { return }
            do { render = try makeRender() }
            catch { renderError = error }
        }
    }

    // MARK: - Blocks

    private func qrBlock(_ render: Render) -> some View {
        VStack(spacing: HueSpacing.sm) {
            Image(uiImage: render.image)
                .resizable()
                .interpolation(.none)          // keep module edges razor sharp
                .scaledToFit()
                .frame(maxWidth: 260)
                .padding(HueSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous)
                        .fill(.white)          // QR readers want a light quiet zone
                )
                .accessibilityLabel("QR code for the scene \(preset.name)")

            Text(render.isDense
                 ? "Point another phone's camera at this. It's a dense code — hold steady."
                 : "Point another phone's camera at this to add the scene.")
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

            // The link always exists even when the QR cannot be drawn — that is
            // the whole reason `tooLarge` is not a fatal error.
            if let url = try? ScenePayloadCodec.encode(preset) {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "link")
                        .font(HueFont.stageChip)
                }
                .tint(HuePalette.amber)
                .padding(.top, HueSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HueSpacing.lg)
    }

    private func linkActions(_ render: Render) -> some View {
        VStack(spacing: HueSpacing.sm) {
            ShareLink(
                item: Image(uiImage: render.image),
                subject: Text(preset.name),
                message: Text(render.url.absoluteString),
                preview: SharePreview(preset.name, image: Image(uiImage: render.image))
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

    // MARK: - Render

    private func makeRender() throws -> Render {
        let url = try ScenePayloadCodec.encode(preset)
        let image = try SceneQRRenderer.render(url)
        return Render(url: url, image: image, isDense: SceneQRRenderer.isDense(url))
    }
}

// MARK: - Palette ribbon

/// A continuous sample of the scene's palette — the fastest way to recognise a
/// scene without running it.
struct ScenePaletteRibbon: View {
    let palette: PaletteConfig
    var steps: Int = 24
    var height: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<steps, id: \.self) { i in
                let phase = steps > 1 ? Double(i) / Double(steps - 1) : 0
                let c = palette.color(at: phase)
                HueColorUtils.color(fromX: c.x, y: c.y, brightness: 100)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.sm, style: .continuous))
        .accessibilityHidden(true)
    }
}
