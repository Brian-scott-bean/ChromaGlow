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
        ShareSheetScaffold(eyebrow: "Share a scene",
                           symbol: "qrcode",
                           tint: Color(hex: preset.accentColorHex),
                           title: preset.name,
                           subtitle: "No account and no upload — the code is the scene.",
                           colors: preset.palette.sampleColors()) {
            VStack(spacing: HueSpacing.lg) {
                ScenePaletteRibbon(palette: preset.palette)

                if let render {
                    qrBlock(render)
                } else if let renderError {
                    failureBlock(renderError)
                } else {
                    ProgressView()
                        .tint(LuminousPalette.ink)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .luminousGlass()

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
        VStack(spacing: HueSpacing.md) {
            Image(uiImage: render.image)
                .resizable()
                .interpolation(.none)          // keep module edges razor sharp
                .scaledToFit()
                .frame(maxWidth: 260)
                .padding(HueSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white)          // QR readers want a light quiet zone
                )
                .shadow(color: Color(hex: preset.accentColorHex).opacity(0.35), radius: 18)
                .accessibilityLabel("QR code for the scene \(preset.name)")

            Text(render.isDense
                 ? "Point another phone's camera at this. It's a dense code — hold steady."
                 : "Point another phone's camera at this to add the scene.")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func failureBlock(_ error: Error) -> some View {
        VStack(spacing: HueSpacing.md) {
            Image(systemName: "qrcode")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LuminousPalette.inkSecondary)

            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // The link always exists even when the QR cannot be drawn — that is
            // the whole reason `tooLarge` is not a fatal error.
            if let url = try? ScenePayloadCodec.encode(preset) {
                ShareLink(item: url) {
                    ShareActionLabel(title: "Share Link", symbol: "link", primary: true)
                }
                .buttonStyle(LuminousPressStyle(scale: 0.96))
                .padding(.top, HueSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HueSpacing.lg)
    }

    private func linkActions(_ render: Render) -> some View {
        VStack(spacing: 10) {
            ShareLink(
                item: Image(uiImage: render.image),
                subject: Text(preset.name),
                message: Text(render.url.absoluteString),
                preview: SharePreview(preset.name, image: Image(uiImage: render.image))
            ) {
                ShareActionLabel(title: "Share QR Image", symbol: "square.and.arrow.up", primary: true)
            }

            ShareLink(item: render.url) {
                ShareActionLabel(title: "Share Link", symbol: "link", primary: false)
            }
        }
        .buttonStyle(LuminousPressStyle(scale: 0.96))
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

extension PaletteConfig {
    /// Three screen colours from a palette (start, middle, end) — for glows.
    func sampleColors() -> [Color] {
        [0.0, 0.5, 1.0].map { phase in
            let c = color(at: phase)
            return HueColorUtils.color(fromX: c.x, y: c.y, brightness: 100)
        }
    }
}

// MARK: - Scaffold

/// The share and import sheets' frame: the scene's glow behind, its name in
/// the title block, content in glass, Done at the top.
struct ShareSheetScaffold<Content: View>: View {
    let eyebrow: String
    let symbol: String
    var tint: Color = LuminousPalette.cyan
    let title: String
    var subtitle: String? = nil
    var colors: [Color] = [LuminousPalette.violet]
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LuminousScreenTitle(title: title, eyebrow: eyebrow, eyebrowSymbol: symbol,
                                        eyebrowTint: tint, subtitle: subtitle)
                    content()
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background { LuminousAmbience(colors: colors) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .luminousSheet()
    }
}

/// A share action's label: the signal button for the main action, glass
/// for the other.
struct ShareActionLabel: View {
    let title: String
    let symbol: String
    var primary: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold))
            Text(title).font(.system(.headline, design: .rounded).weight(.heavy))
        }
        .foregroundStyle(primary ? LuminousPalette.void : LuminousPalette.ink)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 52)
        .background {
            if primary {
                shape.fill(LuminousPalette.signalGradient)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: LuminousPalette.cyan.opacity(0.45), radius: 14)
            }
        }
        .modifier(ShareGlassIfSecondary(primary: primary))
        .contentShape(shape)
    }
}

private struct ShareGlassIfSecondary: ViewModifier {
    let primary: Bool
    func body(content: Content) -> some View {
        if primary { content } else { content.luminousGlass(radius: 18) }
    }
}
