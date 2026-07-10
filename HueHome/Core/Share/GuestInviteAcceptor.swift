// GuestInviteAcceptor.swift
// ChromaGlow — Family Sharing Phase 2 (guest accept, no link button)
//
// A token-bearing invite lands here. Unlike home-join, the guest never
// touches the bridge — the invite carries their own minted key — so THIS
// code owns the identity discipline the pairing flow would otherwise
// provide:
//
//   expiry → no-downgrade guard → live TOFU capture + /api/0/config
//   cross-check → the invite gate (leaf CN == config bid == QR bid AND
//   live pin == QR pinPK AND never overwrite a differing stored pin) →
//   pin persist (the LIVE capture, never QR bytes) → token liveness
//   probe → Keychain + registrar persist → grant seed.
//
// The QR's pinPK is verified-against, never ingested: only a capture the
// device itself observed is ever saved, and only after it equals the
// invite's expectation. We deliberately do NOT reuse
// BridgePinAcquirer.validateAndPersist(unattended:) — no link button was
// pressed, so its presence rule would refuse self-signed bridges; the
// pinPK equality is this flow's presence-equivalent (the owner verified
// that pin interactively when THEY paired). The never-overwrite rule is
// reproduced verbatim.
//
// Design: docs/ios/profiles-access-share-invite-design-2026-07.md §6.2, §2.

import Foundation
import SwiftData

// MARK: - Outcome / seed types

enum GuestInviteAcceptOutcome: Equatable {
    case joined(bridgeRecordID: String)
    case expired
    /// The bridge explicitly refused the token (revoked before accept).
    case revokedBeforeAccept
    /// Transient — nothing persisted, retryable.
    case bridgeUnreachable
    /// The answering bridge does not match the invite. Fail closed.
    case identityMismatch
    /// This phone already holds a FULL credential for the bridge (its own
    /// pairing) — a guest token must never downgrade it.
    case alreadyConnected
    case persistFailed(String)
}

/// What the Phase 3 grant store needs — fired after credentials + record
/// persist, BEFORE the caller integrates the bridge (upsert grant →
/// updateGuestGrants → addBridge → loadAll, so the first fetch is filtered).
struct GuestGrantSeed {
    let bridgeRecordID: String
    let allowedGroupIDs: [String]
    let features: [String]
    let grantedProfileName: String
    let receivedAt: Date
}

// MARK: - GuestInviteAcceptor

@MainActor
final class GuestInviteAcceptor {

    /// Live TOFU identity probe result: the config-reported bridgeid and
    /// the TLS leaf capture from the SAME session.
    struct IdentityProbe {
        let configBridgeID: String
        let capture: PairingLeafCapture
    }

    enum TokenProbe {
        case authorized
        case unauthorized
        case unreachable
    }

    // Test seams — URLProtocol stubs cannot present a server trust, so the
    // live probes are replaceable wholesale.
    var identityProbeOverride: ((SharedBridgeInviteGrant) async -> IdentityProbe?)?
    var tokenProbeOverride: ((SharedBridgeInviteGrant) async -> TokenProbe)?
    var now: () -> Date = { Date() }

    /// Phase 3 hook: persists the GuestAccessGrant. The view wires this to
    /// GuestAccessGrantStore.upsert + orchestrator.updateGuestGrants.
    var onGrantEstablished: ((GuestGrantSeed) -> Void)?

    // ──────────────────────────────────────────────
    // MARK: - Accept (one bridge grant)
    // ──────────────────────────────────────────────

    func accept(
        grant: SharedBridgeInviteGrant,
        profileName: String,
        modelContext: ModelContext
    ) async -> GuestInviteAcceptOutcome {

        // 1 — Expiry, before any network. The TTL bounds the accept window
        //     (±5 min skew grace); the key itself does not expire.
        guard !grant.isExpired(now: now()) else { return .expired }

        let bid = grant.bid.uppercased()

        // 2 — No-downgrade guard. A record already holding readable
        //     credentials WITHOUT a guest grant is this phone's own full
        //     pairing (or the owner's phone scanning its own invite) — a
        //     guest token must never replace it. A record WITH a grant is
        //     guest-owned: fall through so a regenerated/newer invite can
        //     update the token and grant in place (the documented update
        //     path — no owner→guest channel exists).
        if let existing = Self.existingRecord(bid: bid, modelContext: modelContext),
           (try? KeychainManager.shared.loadCredentials(for: existing.id)) != nil {
            let hasGrant = (try? GuestAccessGrantStore.grant(
                for: existing.id, modelContext: modelContext)) != nil
            guard hasGrant else { return .alreadyConnected }
        }

        // 3 — Live identity: fresh TOFU capture + unauthenticated config
        //     cross-check over the SAME session.
        guard let probe = await probeIdentity(grant) else { return .bridgeUnreachable }

        // 4 — The gate (pure, tested in isolation). Fail closed on any
        //     mismatch — nothing has persisted, nothing to clean up.
        let existingPin = BridgePinStore.shared.pin(forBridgeID: probe.capture.bridgeID)
        guard Self.validateInviteCapture(
            capture: probe.capture,
            configBridgeID: probe.configBridgeID,
            grant: grant,
            existingPin: existingPin
        ) else { return .identityMismatch }

        // 5 — Pin persist: the LIVE capture only. By construction it equals
        //     the owner's interactively-verified pin (the gate required
        //     capture == pinPK), so a later transient failure needs no pin
        //     rollback — the pin is correct regardless.
        BridgePinStore.shared.save(pin: probe.capture.pin(host: grant.host))

        // 6 — Token liveness. An EXPLICIT bridge refusal (v1 type 1 /
        //     401/403) means revoked-before-accept; transport failure is
        //     unreachable and persists nothing.
        switch await probeToken(grant) {
        case .unauthorized: return .revokedBeforeAccept
        case .unreachable:  return .bridgeUnreachable
        case .authorized:   break
        }

        // 7 — Persist: per-bridge Keychain slots (clientKey: nil — a guest
        //     key never has one, §7.3) + exactly one BridgeRecord via the
        //     registrar (canonical-bid dedup makes a re-scan idempotent and
        //     moves the credential onto an existing guest record).
        let recordID = UUID().uuidString
        do {
            try KeychainManager.shared.saveCredentials(
                ip: grant.host, token: grant.token, clientKey: nil, for: recordID
            )
        } catch {
            return .persistFailed(error.localizedDescription)
        }
        do {
            let registration = try BridgePairingRegistrar.register(
                mintedID: recordID,
                host: grant.host,
                canonicalBridgeID: bid,
                preferredName: grant.name,
                sortOrder: 999,
                modelContext: modelContext
            )
            onGrantEstablished?(GuestGrantSeed(
                bridgeRecordID: registration.record.id,
                allowedGroupIDs: grant.allowedGroups,
                features: grant.features,
                grantedProfileName: profileName,
                receivedAt: now()
            ))
            return .joined(bridgeRecordID: registration.record.id)
        } catch {
            KeychainManager.shared.deleteCredentials(for: recordID)
            return .persistFailed(error.localizedDescription)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - The gate (pure)
    // ──────────────────────────────────────────────

    /// ALL of: leaf CN == config bridgeid (D-016), config bridgeid == the
    /// invite's bid, live-captured pin == the invite's pinPK, and — when a
    /// pin for this bridgeid already exists — it must equal the capture
    /// (never overwrite; the validateAndPersist MITM rule, reproduced).
    static func validateInviteCapture(
        capture: PairingLeafCapture,
        configBridgeID: String,
        grant: SharedBridgeInviteGrant,
        existingPin: BridgePin?
    ) -> Bool {
        guard capture.bridgeID == configBridgeID,
              configBridgeID == grant.bid.uppercased(),
              capture.publicKeySHA256 == grant.pinPK
        else { return false }
        if let existingPin, existingPin.publicKeySHA256 != capture.publicKeySHA256 {
            return false
        }
        return true
    }

    // ──────────────────────────────────────────────
    // MARK: - Probes (live implementations)
    // ──────────────────────────────────────────────

    private func probeIdentity(_ grant: SharedBridgeInviteGrant) async -> IdentityProbe? {
        if let override = identityProbeOverride { return await override(grant) }
        // The exact shape of BridgePinAcquirer.acquirePin: TOFU-capture
        // delegate + ephemeral session + unauthenticated /api/0/config.
        let delegate = BridgePairingTrustDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        guard let url = URL(string: "https://\(grant.host)/api/0/config") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let configBridgeID = BridgeTrust.bridgeID(fromConfigResponse: data),
                  let capture = delegate.capture else { return nil }
            return IdentityProbe(configBridgeID: configBridgeID, capture: capture)
        } catch {
            return nil
        }
    }

    private func probeToken(_ grant: SharedBridgeInviteGrant) async -> TokenProbe {
        if let override = tokenProbeOverride { return await override(grant) }
        let client = HueV1Client(ip: grant.host, token: grant.token)
        do {
            switch try await client.probeTokenAuthorization() {
            case .authorized:   return .authorized
            case .unauthorized: return .unauthorized
            }
        } catch {
            return .unreachable
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private static func existingRecord(bid: String, modelContext: ModelContext) -> BridgeRecord? {
        var descriptor = FetchDescriptor<BridgeRecord>(
            predicate: #Predicate { $0.bridgeIdentifier == bid }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
