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
        VStack(spacing: 10) {
            statusLine
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Composer2Theme.void.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var buttons: some View {
        Composer2BarButton(title: "Preview", symbol: previewOn ? "eye.fill" : "eye.slash",
                           accent: Composer2Theme.cyan, active: previewOn,
                           accessibilityLabel: previewOn ? "Stop on-screen preview" : "Start on-screen preview") {
            HapticManager.shared.light()
            previewOn.toggle()
        }
        Composer2LiveButton(isLive: isLiveHere, isBusy: center.isBusy,
                            accessibilityLabel: isLiveHere
                                ? "Stop live output to \(document.roomContext.roomName)"
                                : "Start live output to \(document.roomContext.roomName)",
                            action: onLive)
        Composer2BarButton(title: "Save", symbol: document.isDirty ? "square.and.arrow.down.fill" : "square.and.arrow.down",
                           accent: Composer2Theme.violet, active: false, highlighted: document.isDirty,
                           accessibilityLabel: document.isDirty ? "Save changes" : "Save composition") {
            onSave()
        }
        Composer2BarButton(title: "Apply", symbol: ownSession?.isAudition == false ? "checkmark.circle.fill" : "checkmark.circle",
                           accent: Composer2Theme.magenta,
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
            if !center.unresponsiveLights.isEmpty { text = Composer2Copy.liveUnresponsive(center.unresponsiveLights) }
            return text
        default:
            return center.statusText
        }
    }
}

struct Composer2BarButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let symbol: String
    let accent: Color
    let active: Bool
    var highlighted: Bool = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.bounce, value: active)
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? accent : (highlighted ? accent : Composer2Theme.ink.opacity(0.85)))
            .frame(minWidth: 58, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 64)
            .frame(minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(active ? accent.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(active || highlighted ? accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(Composer2PressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// The instrument's one big button. Idle it glows cyan-to-violet; live it
/// turns the live green and breathes.
struct Composer2LiveButton: View {
    let isLive: Bool
    let isBusy: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var fill: LinearGradient {
        isLive
            ? LinearGradient(colors: [Composer2Theme.live, Color(hex: "#1FB5A0")], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Composer2Theme.cyan, Composer2Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(Composer2Theme.void)
                } else {
                    Image(systemName: isLive ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .bold))
                        .symbolEffect(.variableColor.iterative, isActive: isLive && !reduceMotion)
                }
                Text(isLive ? "Stop" : "Go Live")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Composer2Theme.void)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: (isLive ? Composer2Theme.live : Composer2Theme.cyan).opacity(breathe && isLive ? 0.8 : 0.45),
                    radius: breathe && isLive ? 22 : 14)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(Composer2PressStyle(scale: 0.95))
        .frame(maxWidth: .infinity)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
