// PhotosensitivityNotice.swift
// ChromaGlow — the one-time photosensitivity notice (Signify developer terms:
// inform users of possible adverse effects of light effects before use).
//
// Studio Classic shows it from its drain wiring; the Composer tab — the other
// home of flash-capable looks — shows the same notice, behind the same flag,
// so whichever creative surface a person opens first tells them once.
// Gated on tab visibility: an alert fired from an opacity-hidden tab is
// silently dropped by UIKit and swallows the next presentation app-wide.

import SwiftUI

struct PhotosensitivityNotice: ViewModifier {
    @AppStorage("hasSeenPhotosensitivityNotice") private var hasSeen = false
    @State private var showing = false
    @Environment(\.isTabActive) private var isTabActive

    func body(content: Content) -> some View {
        content
            .onAppear { if isTabActive && !hasSeen { showing = true } }
            .onChange(of: isTabActive) { _, active in
                if active && !hasSeen { showing = true }
            }
            .alert("Photosensitivity Notice", isPresented: $showing) {
                Button("OK") { hasSeen = true }
            } message: {
                Text("Some light effects use flashing and rapidly changing colors that may affect people who are sensitive to flashing lights. Effects are limited to 3 flashes per second, and the system Dim Flashing Lights setting is honored.")
            }
    }
}

extension View {
    /// Shows the one-time photosensitivity notice the first time this
    /// surface is on screen.
    func photosensitivityNotice() -> some View {
        modifier(PhotosensitivityNotice())
    }
}
