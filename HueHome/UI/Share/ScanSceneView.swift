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
import AVFoundation

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
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Camera permission, re-read on appear and when returning from Settings.
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Denied/restricted camera access makes `isAvailable` false too — that
    /// is a fixable setting, not "this device can't scan".
    private var cameraBlocked: Bool {
        DataScannerViewController.isSupported
            && (cameraStatus == .denied || cameraStatus == .restricted)
    }

    var body: some View {
        NavigationStack {
            Group {
                if cameraBlocked {
                    cameraDenied
                } else if Self.isSupported {
                    ScannerRepresentable(onFound: handle)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) { hintOverlay }
                } else if DataScannerViewController.isSupported && cameraStatus == .notDetermined {
                    // Ask first; the view re-evaluates when the answer lands.
                    ProgressView()
                        .tint(LuminousPalette.ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                } else {
                    unsupported
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
            .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet]) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(LuminousType.eyebrow)
                        .tracking(1.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(LuminousPalette.ink.opacity(0.85))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        HStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 13, weight: .bold))
                .foregroundStyle(LuminousPalette.cyan)
            Text(hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(LuminousPalette.void.opacity(0.4)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.bottom, HueSpacing.xxl)
    }

    private var cameraDenied: some View {
        LuminousEmptyState(symbol: "camera.fill",
                           title: "Camera access is off.",
                           message: "ChromaGlow needs the camera to read QR codes. Turn it on in Settings, then come back — or ask for the link instead.",
                           actionTitle: "Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .padding(HueSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unsupported: some View {
        LuminousEmptyState(symbol: "qrcode.viewfinder",
                           title: "This device can't scan QR codes.",
                           message: "Ask for the link instead — tapping it does the same thing.")
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
