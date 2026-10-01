// EntertainmentAreasView.swift
// ChromaGlow — Entertainment Areas management (round-2 checkpoint Item 4)
//
// Lists every entertainment_configuration on every connected bridge, with
// rename + delete, and presents EntertainmentConfigBuilderView to create new
// areas. Reached from More → Entertainment Areas. The bridge is the source of
// truth — the Composer and Studio Classic enumerate configs from it when they
// load, so no local state has to be kept in sync here. Luminous page.

import SwiftUI

struct EntertainmentAreasView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator

    @State private var areasByBridge: [String: [EntertainmentConfig]] = [:]
    @State private var isLoading    = false
    @State private var errorMessage: String?
    @State private var showBuilder  = false

    // Rename / delete targets
    @State private var renameTarget:  AreaRef?
    @State private var renameText    = ""
    @State private var showRename    = false
    @State private var deleteTarget:  AreaRef?
    @State private var showDelete    = false

    private let manager = EntertainmentConfigManager()

    private struct AreaRef {
        let bridgeID: String
        let config: EntertainmentConfig
    }

    /// Family Sharing: areas are created, renamed, and deleted on the
    /// bridge itself, so a granted (guest) bridge is never listed or
    /// offered here — only bridges this phone owns.
    private var ownedBridgeIDs: [String] {
        orchestrator.allBridgeIDs.filter { !orchestrator.isGuestGrantedBridge($0) }
    }

    var body: some View {
        LuminousPage(title: "Entertainment Areas",
                     eyebrow: "Control",
                     eyebrowSymbol: "dot.radiowaves.left.and.right",
                     tint: LuminousPalette.cyan,
                     subtitle: "Light zones that answer instantly — the Composer streams its looks to them.",
                     ambience: [LuminousPalette.cyan, LuminousPalette.violet]) {
            if let errorMessage {
                LuminousNotice(text: errorMessage, symbol: "exclamationmark.triangle.fill", tint: LuminousPalette.danger)
            }

            if isLoading && areasByBridge.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(LuminousPalette.cyan)
                    Text("Asking your bridges for their areas…")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .luminousGlass()
            } else if totalAreaCount == 0 {
                emptyState
            } else {
                bridgeSections
            }
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !ownedBridgeIDs.isEmpty {
                    Button {
                        showBuilder = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.bold)
                            .foregroundStyle(LuminousPalette.cyan)
                    }
                    .accessibilityLabel("New Entertainment Area")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showBuilder, onDismiss: { Task { await load() } }) {
            EntertainmentConfigBuilderView()
                .environment(orchestrator)
        }
        .alert("Rename Area", isPresented: $showRename, presenting: renameTarget) { target in
            TextField("Name", text: $renameText)
            Button("Save") {
                let newName = renameText.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty else { return }
                Task { await rename(target, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Rename \"\(target.config.name)\".")
        }
        .alert("Delete Area?", isPresented: $showDelete, presenting: deleteTarget) { target in
            Button("Delete", role: .destructive) {
                Task { await delete(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("\"\(target.config.name)\" will be removed from the bridge. Lights keep working — only the light zone is deleted.")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Sections
    // ──────────────────────────────────────────────

    private var totalAreaCount: Int {
        areasByBridge.values.reduce(0) { $0 + $1.count }
    }

    private var sortedBridgeIDs: [String] {
        areasByBridge.keys.sorted {
            (orchestrator.bridgeName(for: $0) ?? $0) < (orchestrator.bridgeName(for: $1) ?? $1)
        }
    }

    private var bridgeSections: some View {
        ForEach(sortedBridgeIDs, id: \.self) { bridgeID in
            let areas = areasByBridge[bridgeID] ?? []
            // Bridge header — only meaningful in multi-bridge homes, but
            // always shown so the M-18 routing is visible.
            LuminousGroup(title: orchestrator.bridgeName(for: bridgeID) ?? "Bridge") {
                ForEach(Array(areas.enumerated()), id: \.element.id) { index, config in
                    if index > 0 { LuminousRowDivider() }
                    areaRow(bridgeID: bridgeID, config: config)
                }
                if areas.isEmpty {
                    Text("No entertainment areas on this bridge yet.")
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }

    private func areaRow(bridgeID: String, config: EntertainmentConfig) -> some View {
        let lightCount = Set(config.channels.flatMap(\.lightServiceIDs)).count
        return LuminousRow(symbol: "dot.radiowaves.left.and.right", tint: LuminousPalette.cyan,
                           title: config.name,
                           subtitle: "\(lightCount) light\(lightCount == 1 ? "" : "s") · \(config.channels.count) channel\(config.channels.count == 1 ? "" : "s")") {
            Menu {
                Button {
                    renameTarget = AreaRef(bridgeID: bridgeID, config: config)
                    renameText   = config.name
                    showRename   = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteTarget = AreaRef(bridgeID: bridgeID, config: config)
                    showDelete   = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Rename or delete \(config.name)")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if ownedBridgeIDs.isEmpty {
            LuminousEmptyState(symbol: "dot.radiowaves.left.and.right",
                               title: "No Entertainment Areas",
                               message: "Entertainment areas are special light zones that respond instantly — the Composer streams to them, and Studio Classic's directional motion and music sync use them.")
        } else {
            LuminousEmptyState(symbol: "dot.radiowaves.left.and.right",
                               title: "No Entertainment Areas",
                               message: "Entertainment areas are special light zones that respond instantly — the Composer streams to them, and Studio Classic's directional motion and music sync use them.",
                               actionTitle: "New Entertainment Area",
                               action: { showBuilder = true })
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    private func load() async {
        isLoading = true
        errorMessage = nil
        var result: [String: [EntertainmentConfig]] = [:]
        var failures: [String] = []
        for bridgeID in ownedBridgeIDs {
            // This screen is where areas are created, renamed, and deleted, and
            // it fetches its own inventory — so it is exactly where we know the
            // orchestrator's cached one has gone wrong. Nothing invalidated it
            // before: an area edited here was still answered from the pre-edit
            // cache, and a force-quit was the only fix (packet 7 follow-up).
            orchestrator.invalidateEntertainmentCaches(forBridge: bridgeID)
            guard let client = orchestrator.hueClient(for: bridgeID) else { continue }
            do {
                result[bridgeID] = try await manager.fetchConfigs(client: client)
                    .sorted { $0.name < $1.name }
            } catch {
                failures.append(orchestrator.bridgeName(for: bridgeID) ?? "Bridge")
            }
        }
        areasByBridge = result
        if !failures.isEmpty {
            errorMessage = "Couldn't reach: \(failures.joined(separator: ", "))"
        }
        isLoading = false
    }

    private func rename(_ target: AreaRef, to name: String) async {
        guard !orchestrator.isGuestGrantedBridge(target.bridgeID),
              let client = orchestrator.hueClient(for: target.bridgeID) else { return }
        do {
            try await manager.rename(configID: target.config.id, to: name, client: client)
            // Invalidate at the mutation, not only inside `load()`: the rename
            // has already landed on the bridge, so the cached inventory is
            // provably stale even if the reload below fails.
            orchestrator.invalidateEntertainmentCaches(forBridge: target.bridgeID)
            await load()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func delete(_ target: AreaRef) async {
        guard !orchestrator.isGuestGrantedBridge(target.bridgeID),
              let client = orchestrator.hueClient(for: target.bridgeID) else { return }
        do {
            try await manager.delete(configID: target.config.id, client: client)
            // Same reason as rename: the area is gone from the bridge, so any
            // cached verdict still naming it is now a lie.
            orchestrator.invalidateEntertainmentCaches(forBridge: target.bridgeID)
            await load()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
