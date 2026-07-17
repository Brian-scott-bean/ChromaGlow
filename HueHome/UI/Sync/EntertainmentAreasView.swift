// EntertainmentAreasView.swift
// ChromaGlow — Entertainment Areas management (round-2 checkpoint Item 4)
//
// Lists every entertainment_configuration on every connected bridge, with
// rename + delete, and presents EntertainmentConfigBuilderView to create new
// areas. Reached from More → Entertainment Areas. The bridge is the source of
// truth — Studio/Sync enumerate configs from it when they load, so no local
// state has to be kept in sync here.

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
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    private struct AreaRef {
        let bridgeID: String
        let config: EntertainmentConfig
    }

    var body: some View {
        ZStack {
            HuePalette.Noir.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.8))
                    }

                    if isLoading && areasByBridge.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(.white)
                            Spacer()
                        }
                        .padding(.top, 60)
                    } else if totalAreaCount == 0 {
                        emptyState
                    } else {
                        bridgeSections
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.xxl)
                .padding(.bottom, 80)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Entertainment Areas")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showBuilder = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .foregroundStyle(amber)
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
            VStack(alignment: .leading, spacing: 10) {
                // Bridge header — only meaningful in multi-bridge homes,
                // but always shown so the M-18 routing is visible.
                Text((orchestrator.bridgeName(for: bridgeID) ?? "Bridge").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 4)

                GlassmorphicCard(isActive: false, glowColor: amber) {
                    VStack(spacing: 12) {
                        ForEach(Array(areas.enumerated()), id: \.element.id) { index, config in
                            if index > 0 {
                                Divider().background(Color.white.opacity(0.08))
                            }
                            areaRow(bridgeID: bridgeID, config: config)
                        }
                        if areas.isEmpty {
                            Text("No entertainment areas on this bridge yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func areaRow(bridgeID: String, config: EntertainmentConfig) -> some View {
        let lightCount = Set(config.channels.flatMap(\.lightServiceIDs)).count
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(amber.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(amber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                Text("\(lightCount) light\(lightCount == 1 ? "" : "s") · \(config.channels.count) channel\(config.channels.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
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
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(amber.opacity(0.6))
            Text("No Entertainment Areas")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Entertainment areas are special light zones that respond instantly — Studio's directional motion and music sync use them.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button {
                showBuilder = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("New Entertainment Area")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(amber))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    private func load() async {
        isLoading = true
        errorMessage = nil
        var result: [String: [EntertainmentConfig]] = [:]
        var failures: [String] = []
        for bridgeID in orchestrator.allBridgeIDs {
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
        guard let client = orchestrator.hueClient(for: target.bridgeID) else { return }
        do {
            try await manager.rename(configID: target.config.id, to: name, client: client)
            await load()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func delete(_ target: AreaRef) async {
        guard let client = orchestrator.hueClient(for: target.bridgeID) else { return }
        do {
            try await manager.delete(configID: target.config.id, client: client)
            await load()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
