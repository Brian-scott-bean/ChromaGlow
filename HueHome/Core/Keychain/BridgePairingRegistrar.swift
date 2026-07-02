// BridgePairingRegistrar.swift
// ChromaGlow — audit L-15/L-17 (pairing credential persistence + record dedup)
//
// Turns a successful pairing (credentials already sitting in the per-bridge
// namespaced Keychain slots under a freshly minted record id) into exactly one
// BridgeRecord:
//
//  - No existing record for this physical bridge → insert a new record whose
//    id IS the minted Keychain id. Record + credentials share a key from the
//    first moment, so nothing ever lives in the legacy single-bridge slots.
//  - An existing record matches (canonical bridgeid preferred, host as a
//    guarded fallback) → move the credentials onto the EXISTING record id,
//    refresh its host/identity, and delete the minted duplicate slots (L-17:
//    re-pairing must not mint duplicate rows + orphan app keys).
//
// Every failure THROWS so callers surface it — the audit's root complaint was
// a discarded migration result.

import Foundation
import SwiftData

enum BridgePairingRegistrationError: LocalizedError {
    case credentialsUnreadable
    case persistFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .credentialsUnreadable:
            return "The just-paired credentials could not be read back from the Keychain."
        case .persistFailed(let underlying):
            return "The bridge could not be saved: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
enum BridgePairingRegistrar {

    struct Registration {
        let record: BridgeRecord
        /// true when an existing record was reused (re-pairing) instead of inserting a new one.
        let reusedExistingRecord: Bool
    }

    /// Create-or-reuse the BridgeRecord for a pairing whose credentials are
    /// already stored under `mintedID`. Call on the main actor with the view's
    /// ModelContext as soon as the discovery phase reaches `.paired`.
    @discardableResult
    static func register(
        mintedID: String,
        host: String,
        canonicalBridgeID: String?,
        preferredName: String,
        sortOrder: Int,
        modelContext: ModelContext
    ) throws -> Registration {
        let keychain = KeychainManager.shared
        guard let creds = try? keychain.loadCredentials(for: mintedID) else {
            throw BridgePairingRegistrationError.credentialsUnreadable
        }

        let all = (try? modelContext.fetch(FetchDescriptor<BridgeRecord>())) ?? []

        // Dedup (L-17): canonical bridgeid is the physical identity. The host
        // fallback only reuses a record that has never asserted a DIFFERENT
        // identity — two bridges can swap DHCP leases between sessions.
        let existing = all.first { record in
            guard let canonicalBridgeID, let recorded = record.bridgeIdentifier else { return false }
            return recorded == canonicalBridgeID
        } ?? all.first { record in
            record.host == host
                && (record.bridgeIdentifier == nil || record.bridgeIdentifier == canonicalBridgeID)
        }

        if let existing {
            if existing.id != mintedID {
                do {
                    try keychain.saveCredentials(
                        ip: creds.ip,
                        token: creds.token,
                        clientKey: keychain.loadClientKey(for: mintedID),
                        for: existing.id
                    )
                } catch {
                    throw BridgePairingRegistrationError.persistFailed(underlying: error)
                }
                keychain.deleteCredentials(for: mintedID)
            }
            existing.host = host
            existing.isActive = true
            existing.lastSeenAt = Date()
            if let canonicalBridgeID { existing.bridgeIdentifier = canonicalBridgeID }
            do { try modelContext.save() } catch {
                throw BridgePairingRegistrationError.persistFailed(underlying: error)
            }
            return Registration(record: existing, reusedExistingRecord: true)
        }

        let record = BridgeRecord(
            id: mintedID,
            name: preferredName,
            host: host,
            sortOrder: sortOrder,
            bridgeIdentifier: canonicalBridgeID
        )
        modelContext.insert(record)
        do { try modelContext.save() } catch {
            modelContext.delete(record)
            throw BridgePairingRegistrationError.persistFailed(underlying: error)
        }
        return Registration(record: record, reusedExistingRecord: false)
    }
}
