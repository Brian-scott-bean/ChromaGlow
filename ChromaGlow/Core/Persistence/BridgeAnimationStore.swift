// BridgeAnimationStore.swift
// ChromaGlow — Bridge-Stored Animations
//
// Persists BridgeAnimationManifest entries so we can find and clean up
// bridge resources on app restart, even if the app was force-killed
// while an animation was running.

import Foundation
import OSLog

class BridgeAnimationStore {
    static let shared = BridgeAnimationStore()

    private let log = Logger(subsystem: "com.chromaglow.app", category: "BridgeAnimStore")
    private let fileURL: URL
    private var manifests: [String: BridgeAnimationManifest] = [:]  // key = presetID_roomID

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("bridge_animations.json")
        load()
    }

    // MARK: - CRUD

    func save(_ manifest: BridgeAnimationManifest) {
        manifests[manifest.key] = manifest
        persist()
        log.info("[BridgeAnimStore] Saved manifest '\(manifest.presetName)' on '\(manifest.roomName)'")
    }

    func manifest(for presetID: UUID, roomID: String) -> BridgeAnimationManifest? {
        return manifests["\(presetID.uuidString)_\(roomID)"]
    }

    func allManifests() -> [BridgeAnimationManifest] {
        return Array(manifests.values)
    }

    func remove(presetID: UUID, roomID: String) {
        let key = "\(presetID.uuidString)_\(roomID)"
        manifests.removeValue(forKey: key)
        persist()
        log.info("[BridgeAnimStore] Removed manifest for preset=\(presetID) room=\(roomID)")
    }

    func removeAll() {
        manifests.removeAll()
        persist()
        log.info("[BridgeAnimStore] Cleared all manifests")
    }

    /// Check if a specific preset+room has an active bridge animation.
    func isRunningOnBridge(presetID: UUID, roomID: String) -> Bool {
        return manifest(for: presetID, roomID: roomID) != nil
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Array(manifests.values))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("[BridgeAnimStore] Failed to persist: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode([BridgeAnimationManifest].self, from: data)
            for manifest in loaded {
                manifests[manifest.key] = manifest
            }
            log.info("[BridgeAnimStore] Loaded \(loaded.count) manifests from disk")
        } catch {
            log.warning("[BridgeAnimStore] Failed to load: \(error.localizedDescription)")
        }
    }
}
