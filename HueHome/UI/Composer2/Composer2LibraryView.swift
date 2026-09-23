// Composer2LibraryView.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// The Looks tab: every built-in look, filed the way people look for them —
// Halloween, Christmas, holidays, weather, nature, fire, party, calm — plus
// the user's own. One tap tries a look (edits are never discarded without
// asking); the playing look is marked; saved looks can be renamed,
// duplicated or deleted in place.

import SwiftUI

struct Composer2LibraryView: View {
    let document: Composer2Document
    let center: Composer2PlaybackCenter
    var onImport: () -> Void = {}

    @State private var filter: Filter = .forYou
    @State private var renameTarget: Composer2Composition?
    @State private var renameText = ""
    @State private var deleteTarget: Composer2Composition?
    private let store = Composer2Store.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Filter: Hashable {
        case forYou
        case category(Composer2LookCategory)
        case mine
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Composer2SectionTitle(title: "Looks",
                                  subtitle: "\(Composer2ThemeCatalog.entries.count) looks to start from. Tap one to try it — then make it yours.")
            filterBar
            switch filter {
            case .forYou:
                featured
                ForEach(Composer2LookCategory.allCases) { category in
                    categoryRow(category)
                }
                mineSection
            case .category(let category):
                categoryGrid(category)
            case .mine:
                mineSection
            }
            Button(action: {
                HapticManager.shared.light()
                onImport()
            }) {
                Label(Composer2Copy.importLegacyTitle, systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Composer2Theme.cyan)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Composer2Copy.importLegacyHint)
        }
        .alert("Rename look", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete this look?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    HapticManager.shared.medium()
                    store.delete(id: target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\"\(deleteTarget?.name ?? "")\" will be removed from your looks. The built-in looks are never affected.")
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Composer2Chip(title: "For you", symbol: "sparkles", selected: filter == .forYou) { select(.forYou) }
                ForEach(Composer2LookCategory.allCases) { category in
                    Composer2Chip(title: category.shortTitle, symbol: category.symbol,
                                  selected: filter == .category(category),
                                  accent: Composer2Theme.accent(for: category)) { select(.category(category)) }
                }
                if !store.compositions.isEmpty {
                    Composer2Chip(title: "Yours", symbol: "person.crop.circle", selected: filter == .mine,
                                  accent: Composer2Theme.lime) { select(.mine) }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    private func select(_ f: Filter) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { filter = f }
    }

    // MARK: Sections

    private var featured: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Showpieces")
                .font(.caption.weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Composer2Theme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Composer2ThemeCatalog.featured) { entry in
                        card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: entry.category),
                             isNew: entry.isNew, style: .feature)
                            .frame(width: 260)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func categoryRow(_ category: Composer2LookCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { select(.category(category)) }) {
                HStack(spacing: 8) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Composer2Theme.accent(for: category))
                    Text(category.title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Composer2Theme.ink)
                    Spacer(minLength: 0)
                    Text("See all")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Composer2Theme.muted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Composer2Theme.muted)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.title), see all")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Composer2ThemeCatalog.entries(in: category)) { entry in
                        card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: category),
                             isNew: entry.isNew)
                            .frame(width: 168)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    private func categoryGrid(_ category: Composer2LookCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.tagline)
                .font(.subheadline)
                .foregroundStyle(Composer2Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Composer2ThemeCatalog.entries(in: category)) { entry in
                    card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: category),
                         isNew: entry.isNew)
                }
            }
        }
    }

    @ViewBuilder
    private var mineSection: some View {
        if !store.compositions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(Composer2Theme.lime)
                    Text("Your looks")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Composer2Theme.ink)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.compositions) { composition in
                        card(composition, symbol: "person.crop.circle", accent: Composer2Theme.lime, isNew: false)
                            .contextMenu {
                                Button { renameText = composition.name; renameTarget = composition } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button {
                                    HapticManager.shared.light()
                                    store.duplicate(composition)
                                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                Divider()
                                Button(role: .destructive) { deleteTarget = composition } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        } else if filter == .mine {
            Text("Save a look and it lives here.")
                .font(.subheadline)
                .foregroundStyle(Composer2Theme.muted)
        }
    }

    // MARK: Card

    private func card(_ composition: Composer2Composition, symbol: String, accent: Color, isNew: Bool,
                      style: Composer2LookCard.Style = .grid) -> some View {
        Composer2LookCard(composition: composition, symbol: symbol, accent: accent, isNew: isNew,
                          isSelected: document.sourceID == composition.id,
                          isPlaying: center.isLive && center.session?.compositionID == composition.id,
                          style: style) {
            guard document.sourceID != composition.id else { return }
            document.requestReplacement(composition)
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, var current = store.composition(id: target.id) {
            current.name = trimmed
            store.save(current)
            if document.sourceID == target.id, !document.isDirty {
                document.rename(trimmed)
                document.isDirty = false
            }
        }
        renameTarget = nil
    }
}
