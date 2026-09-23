// Composer2Header.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// The top of the instrument: close, the room it plays in, and whether it is
// live — then the look's own title, its category, and whether it has
// unsaved changes.

import SwiftUI

struct Composer2Header: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    let rooms: [RoomDisplayItem]
    let onSelectRoom: (RoomDisplayItem) -> Void
    let onClose: () -> Void

    private var isLiveHere: Bool { center.isPlaying(document: document) }

    var body: some View {
        HStack(spacing: 10) {
            Composer2RoundButton(symbol: "xmark", label: "Close Composer", size: 40, action: onClose)
            roomMenu
            Spacer(minLength: 0)
            if document.canUndo || document.canRedo {
                HStack(spacing: 6) {
                    Composer2RoundButton(symbol: "arrow.uturn.backward", label: "Undo", size: 36) {
                        HapticManager.shared.light()
                        document.undo()
                        Composer2PlaybackCenter.shared.noteEditBurst()
                    }
                    .disabled(!document.canUndo)
                    .opacity(document.canUndo ? 1 : 0.35)
                    Composer2RoundButton(symbol: "arrow.uturn.forward", label: "Redo", size: 36) {
                        HapticManager.shared.light()
                        document.redo()
                        Composer2PlaybackCenter.shared.noteEditBurst()
                    }
                    .disabled(!document.canRedo)
                    .opacity(document.canRedo ? 1 : 0.35)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                stateChip
            }
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Composer2Theme.cyan)
                Text(document.roomContext.roomName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Composer2Theme.muted)
            }
            .foregroundStyle(Composer2Theme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
        .disabled(center.isBusy)
        .accessibilityLabel("Room: \(document.roomContext.roomName), \(Composer2Copy.lights(document.roomContext.lightCount))")
        .accessibilityHint("Choose the room this look plays in")
    }

    private var stateChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLiveHere ? Composer2Theme.live : Composer2Theme.muted)
                .frame(width: 7, height: 7)
                .shadow(color: isLiveHere ? Composer2Theme.live : .clear, radius: 4)
            Text(chipText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Composer2Theme.ink.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityLabel("Connection: \(chipText)")
    }

    private var chipText: String {
        if isLiveHere { return center.statusText }
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

    private var entry: Composer2LookEntry? {
        document.sourceID.flatMap { Composer2ThemeCatalog.entry(id: $0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: HueSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let entry {
                        Label(entry.category.title, systemImage: entry.category.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Composer2Theme.accent(for: entry.category))
                    } else if Composer2Store.shared.compositions.contains(where: { $0.id == document.sourceID }) {
                        Label("Your look", systemImage: "person.crop.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Composer2Theme.lime)
                    }
                    if document.isDirty {
                        Text("EDITED")
                            .font(.caption2.weight(.heavy))
                            .tracking(1)
                            .foregroundStyle(Composer2Theme.amber)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 18)
                            .background(Capsule().strokeBorder(Composer2Theme.amber.opacity(0.6), lineWidth: 1))
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                Text(document.composition.name)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [Composer2Theme.ink, Composer2Theme.ink.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !document.composition.subtitle.isEmpty {
                    Text(document.composition.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Composer2Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Composer2RoundButton(symbol: "pencil", label: "Rename look", size: 40, tint: Composer2Theme.cyan) {
                draftName = document.composition.name
                draftSubtitle = document.composition.subtitle
                renaming = true
                HapticManager.shared.light()
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            TextField("Subtitle", text: $draftSubtitle)
            Button("Save") { document.rename(draftName, subtitle: draftSubtitle) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
