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
    /// The quarantine sidecar (round 3): durable evidence for manifests whose
    /// NORMAL persist failed while their bridge resources could not be fully
    /// compensated away. The main file's write just failed, so writing the
    /// same file again is not an answer — this is a second, independent
    /// location whose only job is surviving a relaunch.
    private let quarantineFileURL: URL
    /// Ids currently carried by the quarantine sidecar.
    private var quarantinedIDs: Set<UUID> = []

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
        quarantineFileURL = docs.appendingPathComponent("bridge_animations_quarantine.json")
        load()
    }

    #if DEBUG
    /// An isolated store for tests.
    ///
    /// Without this every test shares one process-wide instance backed by the
    /// real Documents file, so a sibling test's set-up can empty the store
    /// while this one is suspended inside a production settle window — and the
    /// assertions here are all about which exact manifests exist.
    ///
    /// `quarantineFileURL` is separately controllable so a test can make the
    /// main persist fail while the quarantine write succeeds — the exact
    /// situation the sidecar exists for — and vice versa.
    init(fileURL: URL, quarantineFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.quarantineFileURL = quarantineFileURL
            ?? fileURL.deletingPathExtension().appendingPathExtension("quarantine.json")
        load()
    }
    #endif

    // MARK: - CRUD

    /// Save a manifest, reporting whether it actually reached disk.
    ///
    /// The result is load-bearing, not decoration. A manifest is the ONLY thing
    /// that makes bridge resources nameable and stoppable after a relaunch, so
    /// "saved and running on the bridge" is a claim about this write having
    /// succeeded. `persist()` swallowed its error, which made an in-memory
    /// manifest and a failed write indistinguishable to every caller — and the
    /// caller went on to start the animation either way.
    @discardableResult
    func save(_ manifest: BridgeAnimationManifest) -> Bool {
        manifests[manifest.id] = manifest
        revision &+= 1
        let persisted = persist()
        if persisted {
            log.info("[BridgeAnimStore] Saved manifest '\(manifest.presetName)' on '\(manifest.roomName)'")
        } else {
            log.error("[BridgeAnimStore] Manifest '\(manifest.presetName)' did NOT reach disk")
        }
        return persisted
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
    ///
    /// Removal also clears the id's quarantine record: every caller reaches
    /// this through the exact-identity forget funnel, which is entered only
    /// on proven deletion — the same rule that admitted the record.
    func remove(id: UUID) {
        guard manifests.removeValue(forKey: id) != nil else { return }
        revision &+= 1
        persist()
        removeQuarantined(id: id)
        log.info("[BridgeAnimStore] Removed manifest \(id)")
    }

    // MARK: - Quarantine (round 3)

    /// Durably record a manifest whose NORMAL persist failed while its bridge
    /// resources provably (or possibly) remain. Returns whether the record
    /// actually reached disk — `false` means a relaunch may lose the only
    /// exact handle, and the caller owes the user that sentence.
    ///
    /// The manifest stays in the in-memory map either way; quarantine is
    /// about surviving the relaunch, not about this session.
    @discardableResult
    func quarantine(_ manifest: BridgeAnimationManifest) -> Bool {
        quarantinedIDs.insert(manifest.id)
        do {
            let records = manifests.values.filter { quarantinedIDs.contains($0.id) }
            let data = try JSONEncoder().encode(Array(records))
            try data.write(to: quarantineFileURL, options: .atomic)
            log.info("[BridgeAnimStore] Quarantined manifest '\(manifest.presetName)' for relaunch recovery")
            return true
        } catch {
            log.error("[BridgeAnimStore] Quarantine write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The ids the quarantine sidecar currently carries.
    func quarantinedManifestIDs() -> Set<UUID> { quarantinedIDs }

    /// Drop one id from the sidecar. Reached only via `remove(id:)` — i.e.
    /// only after complete deletion was proven through the forget funnel.
    private func removeQuarantined(id: UUID) {
        guard quarantinedIDs.remove(id) != nil else { return }
        do {
            let records = manifests.values.filter { quarantinedIDs.contains($0.id) }
            if records.isEmpty {
                try? FileManager.default.removeItem(at: quarantineFileURL)
            } else {
                let data = try JSONEncoder().encode(Array(records))
                try data.write(to: quarantineFileURL, options: .atomic)
            }
        } catch {
            log.warning("[BridgeAnimStore] Quarantine rewrite failed: \(error.localizedDescription)")
        }
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

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(Array(manifests.values))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            log.error("[BridgeAnimStore] Failed to persist: \(error.localizedDescription)")
            return false
        }
    }

    /// Never writes. A file this cannot parse is left exactly as it is for a
    /// later build to read — overwriting it would destroy the only record of
    /// animations still running on a bridge.
    ///
    /// The quarantine sidecar loads alongside the main file, so a manifest
    /// whose normal persist failed is an ordinary manifest again on the next
    /// launch: the reconciler and the exact Stop see it with no special
    /// path. Quarantine wins nothing over the main file — the two describe
    /// disjoint failure histories, and an id present in both is simply the
    /// same record.
    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
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
        if FileManager.default.fileExists(atPath: quarantineFileURL.path) {
            do {
                let data = try Data(contentsOf: quarantineFileURL)
                let recovered = try Self.decodeManifests(data)
                for manifest in recovered {
                    manifests[manifest.id] = manifest
                    quarantinedIDs.insert(manifest.id)
                }
                log.info("[BridgeAnimStore] Recovered \(recovered.count) quarantined manifest(s)")
            } catch {
                log.warning("[BridgeAnimStore] Failed to load quarantine: \(error.localizedDescription)")
            }
        }
    }
}
