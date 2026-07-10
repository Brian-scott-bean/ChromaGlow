// GuestRevocationService.swift
// ChromaGlow — Family Sharing Phase 4 (owner-side revoke)
//
// Revoking a guest does two things, in honesty order (design §4):
//  1. BEST-EFFORT bridge-side delete of their minted key — the owner
//     knows the exact whitelist element (it IS the guest token), so no
//     whitelist listing is needed. Verified by re-read; expected to be
//     refused on modern firmware.
//  2. ALWAYS the owner-side wipe: the stored guest key leaves this
//     phone's Keychain, so the QR can never be re-shown or regenerated.
//     The CALLER marks GuestProfile.revokedAt (the mint sheet already
//     refuses revoked specs).
//
// The report tells the UI which truth to speak per bridge: "fully signed
// out" vs the official-Hue-app fallback copy.

import Foundation

enum RevocationBridgeOutcome: Equatable {
    /// The bridge itself no longer lists the key — the guest is fully out.
    case revokedOnBridge
    /// Only this phone forgot the key; bridge-side access survives until
    /// official Hue tooling revokes it. `reason` is display-safe.
    case localOnly(reason: String)
    /// Transport failure — the local wipe still happened.
    case bridgeUnreachable
}

struct RevocationReport {
    /// Keyed by bridgeRecordID.
    let perBridge: [String: RevocationBridgeOutcome]

    /// True when every reached bridge verified the delete.
    var fullyRevokedEverywhere: Bool {
        !perBridge.isEmpty && perBridge.values.allSatisfy { $0 == .revokedOnBridge }
    }
}

@MainActor
enum GuestRevocationService {

    /// Revoke every key this profile was issued. `deleteOnBridge` is the
    /// test seam; the default routes through the owner's own credentials
    /// and HueV1Client.deleteWhitelistEntry.
    static func revoke(
        profileID: String,
        mintedKeyRefs: [String],
        deleteOnBridge: ((_ bridgeRecordID: String, _ guestToken: String) async -> RevocationBridgeOutcome)? = nil
    ) async -> RevocationReport {
        var perBridge: [String: RevocationBridgeOutcome] = [:]

        for ref in mintedKeyRefs {
            guard let parsed = GuestKeyStore.parse(accountRef: ref),
                  parsed.profileID == profileID else { continue }
            let bridgeRecordID = parsed.bridgeRecordID

            var outcome: RevocationBridgeOutcome =
                .localOnly(reason: "No stored key for this bridge — nothing to revoke there.")
            if let guestToken = GuestKeyStore.loadGuestToken(
                profileID: profileID, bridgeRecordID: bridgeRecordID) {
                if let deleteOnBridge {
                    outcome = await deleteOnBridge(bridgeRecordID, guestToken)
                } else {
                    outcome = await liveDelete(bridgeRecordID: bridgeRecordID,
                                               guestToken: guestToken)
                }
            }

            // The owner-side wipe happens REGARDLESS of the bridge outcome —
            // this phone must never be able to re-issue the QR.
            GuestKeyStore.deleteGuestToken(profileID: profileID,
                                           bridgeRecordID: bridgeRecordID)
            perBridge[bridgeRecordID] = outcome
        }

        return RevocationReport(perBridge: perBridge)
    }

    private static func liveDelete(
        bridgeRecordID: String,
        guestToken: String
    ) async -> RevocationBridgeOutcome {
        guard let creds = try? KeychainManager.shared.loadCredentials(for: bridgeRecordID) else {
            return .localOnly(reason: "This phone no longer holds that bridge's credentials.")
        }
        let client = HueV1Client(ip: creds.ip, token: creds.token)
        do {
            switch try await client.deleteWhitelistEntry(element: guestToken) {
            case .deletedVerified:
                return .revokedOnBridge
            case .unsupportedByFirmware(let reason):
                return .localOnly(reason: reason)
            case .stillPresent:
                return .localOnly(reason: "The bridge kept the key despite claiming success.")
            }
        } catch {
            return .bridgeUnreachable
        }
    }
}
