// Composer2PerformanceBar.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Preview · Live · Save · Apply, plus one honest status line. Live is never
// disabled on a cached verdict: tapping it always answers, in words, why it
// can or cannot go out to the lights.

import SwiftUI

struct Composer2PerformanceBar: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    @Binding var previewOn: Bool
    let onLive: () -> Void
    let onSave: () -> Void
    let onApply: () -> Void
    let onDismissNotice: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// This document is what the lights play (not merely "something is live").
    private var isLiveHere: Bool { center.isPlaying(document: document) }
    private var ownSession: Composer2PlaybackCenter.Session? { isLiveHere ? center.session : nil }

    var body: some View {
        VStack(spacing: 8) {
            statusLine
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(.horizontal, HueSpacing.lg)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Composer2Theme.navy.opacity(0.65))
                .overlay(alignment: .top) { Rectangle().fill(Composer2Theme.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var buttons: some View {
        Composer2BarButton(title: previewOn ? "Preview" : "Preview", symbol: previewOn ? "eye.fill" : "eye",
                           accent: Composer2Theme.cyan, active: previewOn,
                           accessibilityLabel: previewOn ? "Stop on-screen preview" : "Start on-screen preview") {
            HapticManager.shared.light()
            previewOn.toggle()
        }
        Composer2BarButton(title: isLiveHere ? "Stop" : "Live", symbol: isLiveHere ? "stop.fill" : "dot.radiowaves.left.and.right",
                           accent: Composer2Theme.live, active: isLiveHere,
                           accessibilityLabel: isLiveHere
                               ? "Stop live output to \(document.roomContext.roomName)"
                               : "Start live output to \(document.roomContext.roomName)") {
            onLive()
        }
        Composer2BarButton(title: "Save", symbol: "square.and.arrow.down", accent: Composer2Theme.violet,
                           active: false, accessibilityLabel: "Save composition") {
            onSave()
        }
        Composer2BarButton(title: "Apply", symbol: "checkmark.circle", accent: Composer2Theme.magenta,
                           active: ownSession?.isAudition == false,
                           accessibilityLabel: "Apply composition to \(document.roomContext.roomName)") {
            onApply()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isLiveHere ? Composer2Theme.live : (previewOn ? Composer2Theme.cyan : Composer2Theme.muted))
                .frame(width: 7, height: 7)
                .shadow(color: isLiveHere ? Composer2Theme.live.opacity(0.8) : .clear, radius: 5)
            Text(statusText)
                .font(HueFont.stageStatus)
                .foregroundStyle(Composer2Theme.ink.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isNotice {
                Button {
                    onDismissNotice()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Composer2Theme.muted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusText)")
    }

    private var isNotice: Bool {
        switch center.status {
        case .ended, .failed: return true
        default: return false
        }
    }

    private var statusText: String {
        if center.isLive, !isLiveHere {
            // Something else is playing (a look applied from the Studio card);
            // this screen is only previewing.
            return previewOn ? Composer2Copy.previewOnly : "Paused"
        }
        switch center.status {
        case .idle:
            if previewOn { return document.roomContext.isDemo ? "Preview · \(Composer2Copy.demoHome)" : Composer2Copy.previewOnly }
            return document.roomContext.isDemo ? Composer2Copy.demoHome : "Paused"
        case .live:
            var text = center.statusText
            if ownSession?.isAudition == true { text += " · " + Composer2Copy.auditionHint }
            if center.severalAreas, ownSession?.playMode == .roomMode { text = Composer2Copy.liveSeveralAreas }
            return text
        default:
            return center.statusText
        }
    }
}

struct Composer2BarButton: View {
    let title: String
    let symbol: String
    let accent: Color
    let active: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(HueFont.stageChip)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Composer2Theme.background : Composer2Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? accent : Composer2Theme.glassRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? accent.opacity(0.9) : Composer2Theme.line, lineWidth: 1)
            )
            .shadow(color: active ? accent.opacity(0.45) : .clear, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
