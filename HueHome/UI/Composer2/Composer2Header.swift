// Composer2Header.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The top of the instrument: the name of the surface, the room it is
// composing for, a compact connection/state chip, and the composition's own
// title block with rename.

import SwiftUI

struct Composer2Header: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    let rooms: [RoomDisplayItem]
    let onSelectRoom: (RoomDisplayItem) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HueSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(Composer2Copy.title)
                        .font(HueFont.displayMedium)
                        .foregroundStyle(Composer2Theme.ink)
                    StageBadge(text: Composer2Copy.experimentalBadge, style: .amber)
                }
                Text(Composer2Copy.tagline)
                    .font(HueFont.subheadline)
                    .foregroundStyle(Composer2Theme.muted)
                HStack(spacing: 8) {
                    roomMenu
                    stateChip
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Composer2Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Composer2Theme.glassRaised))
                    .overlay(Circle().strokeBorder(Composer2Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Composer")
        }
    }

    private var roomMenu: some View {
        Menu {
            if rooms.isEmpty {
                Text("No rooms available")
            }
            ForEach(rooms, id: \.id) { room in
                Button {
                    onSelectRoom(room)
                } label: {
                    Label(room.name, systemImage: room.kind == .zone ? "square.stack.3d.up" : "house")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "house.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(document.roomContext.roomName)
                    .font(HueFont.stageChip)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(2)
                Text("·")
                    .foregroundStyle(Composer2Theme.muted)
                Text(Composer2Copy.lights(document.roomContext.lightCount))
                    .font(HueFont.stageChip)
                    .foregroundStyle(Composer2Theme.muted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Composer2Theme.muted)
            }
            .foregroundStyle(Composer2Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(Composer2Theme.glassRaised))
            .overlay(Capsule().strokeBorder(Composer2Theme.line, lineWidth: 1))
        }
        .accessibilityLabel("Room: \(document.roomContext.roomName), \(Composer2Copy.lights(document.roomContext.lightCount))")
        .accessibilityHint("Choose the room this composition plays in")
    }

    private var stateChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(center.isLive ? Composer2Theme.live : Composer2Theme.muted)
                .frame(width: 6, height: 6)
            Text(chipText)
                .font(HueFont.stageStatus)
                .foregroundStyle(Composer2Theme.ink.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(Capsule().fill(Composer2Theme.glass))
        .overlay(Capsule().strokeBorder(Composer2Theme.line, lineWidth: 1))
        .accessibilityLabel("Connection: \(chipText)")
    }

    private var chipText: String {
        if center.isLive { return center.statusText }
        if document.roomContext.isDemo { return Composer2Copy.demoHome }
        return document.roomContext.connectionText.isEmpty ? Composer2Copy.previewOnly : document.roomContext.connectionText
    }
}

// MARK: - Title block

struct Composer2TitleBlock: View {
    let document: Composer2Document
    @State private var renaming = false
    @State private var draftName = ""
    @State private var draftSubtitle = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HueSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.composition.name)
                    .font(HueFont.displayLarge)
                    .foregroundStyle(Composer2Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(document.composition.subtitle.isEmpty ? " " : document.composition.subtitle)
                    .font(HueFont.subheadline)
                    .foregroundStyle(Composer2Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                draftName = document.composition.name
                draftSubtitle = document.composition.subtitle
                renaming = true
                HapticManager.shared.light()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Composer2Theme.cyan)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Composer2Theme.cyan.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Composer2Theme.cyan.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename composition")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            TextField("Subtitle", text: $draftSubtitle)
            Button("Save") { document.rename(draftName, subtitle: draftSubtitle) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
