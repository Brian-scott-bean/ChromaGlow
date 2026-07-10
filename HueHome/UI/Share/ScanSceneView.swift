// ScanSceneView.swift
// ChromaGlow — scene sharing
//
// Points the camera at someone else's QR and hands the URL back. Uses VisionKit's
// DataScannerViewController, which does the recognition on-device — no frame
// ever leaves the phone, and nothing is recorded.
//
// DataScanner is unavailable on the Simulator and on devices without a Neural
// Engine, so `isSupported` is checked before presenting and the view degrades to
// an explanation rather than a black rectangle.

import SwiftUI
import VisionKit

struct ScanSceneView: View {

    /// Surface strings — the invite flow reuses this scanner with its own
    /// wording. Defaults preserve the scene-scanner call sites verbatim.
    var title: String = "SCAN A SCENE"
    var hint: String = "Point at a ChromaGlow scene QR code"

    /// Called once with the first recognised ChromaGlow share link. The caller
    /// dismisses and presents the import preview (or the join flow — wrong-kind
    /// links surface as honest decode errors there, not silent non-matches).
    let onFound: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if Self.isSupported {
                    ScannerRepresentable(onFound: handle)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) { hintOverlay }
                } else {
                    unsupported
                }
            }
            .background(StagePalette.stage)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(HueFont.stageTag)
                        .tracking(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(StagePalette.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(HuePalette.amber)
                }
            }
            .toolbarBackground(StagePalette.stage, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    /// Only ChromaGlow share links are accepted. A stray QR on a coffee cup
    /// should not dismiss the scanner with an error — it should simply not match.
    private func handle(_ text: String) {
        guard let url = URL(string: text), ScenePayloadCodec.isShareLink(url) else { return }
        HapticManager.shared.medium()
        onFound(url)
        dismiss()
    }

    private var hintOverlay: some View {
        Text(hint)
            .font(HueFont.stageStatus)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(.bottom, HueSpacing.xxl)
    }

    private var unsupported: some View {
        VStack(spacing: HueSpacing.md) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(StagePalette.muted)
            Text("This device can't scan QR codes.")
                .font(HueFont.stageControl)
                .foregroundStyle(StagePalette.ink)
            Text("Ask for the scene link instead — tapping it adds the scene.")
                .font(HueFont.stageStatus)
                .foregroundStyle(StagePalette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HueSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - VisionKit bridge

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !context.coordinator.isScanning else { return }
        context.coordinator.isScanning = (try? controller.startScanning()) != nil
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        /// One scene per presentation — the delegate fires per frame while the
        /// code stays in view, and a second import would duplicate the preset.
        private var didFire = false
        var isScanning = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            consume(items)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            consume([item])
        }

        private func consume(_ items: [RecognizedItem]) {
            guard !didFire else { return }
            for case .barcode(let barcode) in items {
                guard let payload = barcode.payloadStringValue,
                      let url = URL(string: payload),
                      ScenePayloadCodec.isShareLink(url)
                else { continue }
                didFire = true
                onFound(payload)
                return
            }
        }
    }
}
