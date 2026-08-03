// BridgeAnimationStore.swift
// ChromaGlow — Bridge-Stored Animations
//
// Persists BridgeAnimationManifest entries so we can find and clean up
// bridge resources on app restart, even if the app was force-killed
// while an animation was running.

import Foundation
import OSLog

// @MainActor: the only production caller is the main-actor UnifiedOrchestrator,
// so every real access already runs on main — this types that fact.
@MainActor
final class BridgeAnimationStore {
    static let shared = BridgeAnimationStore()

    private let log = Logger(subsystem: "com.chromaglow.app", category: "BridgeAnimStore")
    private let fileURL: URL

    /// Keyed by MANIFEST ID (packet 8), not by `presetID_roomID`.
    ///
    /// The old composite key made the same preset, in the same room id, on TWO
    /// bridges into ONE entry: saving the second silently destroyed the only
    /// record of the first, and that first animation then looped on its bridge
    /// forever with nothing left in the app able to name its resources.
    ///
    /// This is a key-only migration. The on-disk format has always been a JSON
    /// ARRAY of manifests (see `persist()`), so legacy files re-key losslessly,
    /// and no two legacy records can collide because the old key already
    /// deduplicated them at save time.
    private var manifests: [UUID: BridgeAnimationManifest] = [:]

    /// Bumped by every mutation. Reconciliation computes decisions across a
    /// network await and must be able to ask "did the store move under me?"
    /// without diffing the whole collection.
    private(set) var revision: Int = 0

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("bridge_animations.json")
        load()
    }

    #if DEBUG
    /// An isolated store for tests.
    ///
    /// Without this every test shares one process-wide instance backed by the
    /// real Documents file, so a sibling test's set-up can empty the store
    /// while this one is suspended inside a production settle window — and the
    /// assertions here are all about which exact manifests exist.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }
    #endif

    // MARK: - CRUD

    func save(_ manifest: BridgeAnimationManifest) {
        manifests[manifest.id] = manifest
        revision &+= 1
        persist()
        log.info("[BridgeAnimStore] Saved manifest '\(manifest.presetName)' on '\(manifest.roomName)'")
    }

    /// Exact lookup. The manifest id is the only identity that cannot collide
    /// across bridges, rooms or repeated uploads of one preset.
    func manifest(id: UUID) -> BridgeAnimationManifest? {
        return manifests[id]
    }

    func allManifests() -> [BridgeAnimationManifest] {
        return Array(manifests.values)
    }

    /// The manifests this room owns ON THIS EXACT BRIDGE (packet 2, tightened
    /// by packet 8).
    ///
    /// `roomID` alone is not ownership: the same room id can appear in
    /// manifests recorded against two different bridges, and cleaning one of
    /// those against the other's client aims deletes at a bridge that never
    /// held the resources while dropping the manifest that was the only record
    /// of them.
    ///
    /// `bridgeID` is authoritative when the manifest carries one. `bridgeIP` is
    /// consulted ONLY for legacy manifests written before packet 8, and the
    /// caller is responsible for having resolved that IP to exactly one
    /// registered bridge first — this method cannot see the client registry and
    /// deliberately does not guess on its behalf.
    ///
    /// Order is dictionary order and is deliberately not a contract — callers
    /// clean every returned manifest, and each manifest's own teardown order is
    /// what has to be dependency-safe.
    func ownedManifests(roomID: String, bridgeID: String, bridgeIP: String) -> [BridgeAnimationManifest] {
        return manifests.values.filter { manifest in
            guard manifest.roomID == roomID else { return false }
            if let recorded = manifest.bridgeID { return recorded == bridgeID }
            return manifest.bridgeIP == bridgeIP
        }
    }

    /// Exact removal. There is deliberately no roomID-only or preset+room
    /// removal: both could destroy a different bridge's live evidence.
    func remove(id: UUID) {
        guard manifests.removeValue(forKey: id) != nil else { return }
        revision &+= 1
        persist()
        log.info("[BridgeAnimStore] Removed manifest \(id)")
    }

    /// Stamp a legacy IP-only manifest with a stable bridge id.
    ///
    /// Writes ONLY when the manifest still exists and has no id yet — the
    /// caller must already have resolved exactly one registered bridge for it.
    /// Returns nil and persists NOTHING otherwise, which is what "ambiguous or
    /// unmapped legacy identity means zero mutation" looks like at the storage
    /// layer.
    @discardableResult
    func adoptBridgeID(_ bridgeID: String, forManifestID id: UUID) -> BridgeAnimationManifest? {
        guard let existing = manifests[id], existing.bridgeID == nil else { return nil }
        let upgraded = existing.adoptingBridgeID(bridgeID)
        manifests[id] = upgraded
        revision &+= 1
        persist()
        log.info("[BridgeAnimStore] Adopted bridgeID for manifest \(id)")
        return upgraded
    }

    // MARK: - Persistence

    /// The decoder as a pure function, so the legacy-payload guarantee is
    /// testable without touching the real Documents file (mirrors
    /// `HueV1Client.decodeReportedCapacity`).
    nonisolated static func decodeManifests(_ data: Data) throws -> [BridgeAnimationManifest] {
        return try JSONDecoder().decode([BridgeAnimationManifest].self, from: data)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Array(manifests.values))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("[BridgeAnimStore] Failed to persist: \(error.localizedDescription)")
        }
    }

    /// Never writes. A file this cannot parse is left exactly as it is for a
    /// later build to read — overwriting it would destroy the only record of
    /// animations still running on a bridge.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try Self.decodeManifests(data)
            for manifest in loaded {
                manifests[manifest.id] = manifest
            }
            log.info("[BridgeAnimStore] Loaded \(loaded.count) manifests from disk")
        } catch {
            log.warning("[BridgeAnimStore] Failed to load: \(error.localizedDescription)")
        }
    }
}
