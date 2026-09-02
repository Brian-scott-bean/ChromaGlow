package com.chromaglow.app.core.hue.pairing.workflow

import com.chromaglow.app.core.bridge.BridgeRegistry
import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.transport.HuePairingClient
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Transactional, off-main-thread workflow that turns a selected Setup endpoint into a durably
 * registered, locally-secured pairing — and reverses it.
 *
 * Security/threading contract:
 *  - The blocking pairing call and the blocking Keystore reads/writes run on the injected
 *    [ioDispatcher]; the suspend API is main-safe.
 *  - The application key/username never escapes into a returned value: success exposes only the
 *    non-secret [PairedBridgeRecord]. Persistence is two-phase with compensation, so a "Paired"
 *    result always means BOTH the token and the metadata are committed.
 *  - Every terminal failure is a closed, UI-safe [PairingErrorReason]; no raw exception text,
 *    response body, bridge id, or path is exposed.
 *
 * All collaborators are injected so the workflow is exercised deterministically with fakes; no
 * real bridge, Keystore, or DataStore is required in tests.
 */
class LivePairingWorkflow(
    private val pairingClient: HuePairingClient,
    private val credentialStore: BridgeCredentialStore,
    private val bridgeRegistry: BridgeRegistry,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {

    /**
     * Attempt to pair with the [selected] endpoint. The pairing endpoint is derived from the
     * selected name/host with the fixed accepted HTTPS port ([PAIRING_PORT]); the selected endpoint's
     * advertised (often HTTP) port is ignored and the discovery model is not mutated.
     */
    suspend fun pair(selected: BridgeEndpoint): PairingOutcome {
        val endpoint = BridgeEndpoint(name = selected.name, host = selected.host, port = PAIRING_PORT)

        // Blocking transport call off the main thread. No hint is supplied; the transport
        // authenticates the canonical id from the CA-validated leaf across both legs.
        // runCatching (audit L-38): the transport is contractually non-throwing, but a defect
        // below it must degrade to a typed, UI-safe failure instead of crashing the caller's scope.
        // CancellationException is rethrown so structured cancellation is preserved.
        val result = withContext(ioDispatcher) {
            try {
                pairingClient.pair(endpoint, expectedBridgeId = null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                HuePairingResult.Failure(PairingFailureReason.TransportError)
            }
        }

        return when (result) {
            is HuePairingResult.Success -> {
                // The record guard (canonical id, non-blank name/host) can only fail if the
                // transport handed back something outside its contract; that is a typed,
                // persist-nothing failure, never an exception out of pair().
                val record = try {
                    activeRecord(result.bridgeId, endpoint)
                } catch (_: IllegalArgumentException) {
                    return PairingOutcome.Failed(PairingErrorReason.BRIDGE_RESPONSE_INVALID)
                }
                // The two-phase commit is a critical section: a cancelled caller (navigation,
                // process teardown) must never leave token-without-metadata or half state behind.
                // NonCancellable is scoped to persistence only; the network call above stays
                // cancellable.
                withContext(NonCancellable) {
                    persist(record = record, username = result.username)
                }
            }

            HuePairingResult.LinkButtonNotPressed -> PairingOutcome.LinkButtonRequired

            is HuePairingResult.Failure -> PairingOutcome.Failed(result.reason.toErrorReason())
        }
    }

    /**
     * Two-phase local persistence with compensation: save the token first, then upsert metadata.
     * If metadata fails, the just-saved token is best-effort deleted so a half-committed state is
     * never reported as paired. The token is consumed here and never returned.
     */
    private suspend fun persist(record: PairedBridgeRecord, username: String): PairingOutcome {
        val tokenSaved = withContext(ioDispatcher) {
            runCatching { credentialStore.saveApiToken(record.bridgeId, username) }.isSuccess
        }
        if (!tokenSaved) {
            // Token save failed: no metadata is written.
            return PairingOutcome.Failed(PairingErrorReason.LOCAL_PERSISTENCE)
        }

        return when (bridgeRegistry.upsert(record)) {
            is BridgeRegistryResult.Success -> PairingOutcome.Paired(record)
            else -> {
                // Compensate: roll back the token so we never leave token-without-metadata.
                withContext(ioDispatcher) {
                    runCatching { credentialStore.deleteApiToken(record.bridgeId) }
                }
                PairingOutcome.Failed(PairingErrorReason.LOCAL_PERSISTENCE)
            }
        }
    }

    /**
     * Reconstruct the paired state at startup. Only a record paired with a readable token is a
     * valid [RestoredState.Paired] session.
     *
     * Credential/metadata mismatches are CLASSIFIED, never repaired destructively: a record whose
     * token is missing or unreadable is [RestoredState.NeedsRepair]; unreadable metadata is
     * [RestoredState.Unavailable]. This method never deletes a credential or a record — a corrupt
     * or transiently unreadable store must not destroy a valid token. Deletion happens only through
     * the failed-pairing compensation in [pair], the user's explicit [forget], or the user's
     * explicit [resetMetadata].
     */
    suspend fun restore(): RestoredState {
        val active = when (val bridges = bridgeRegistry.bridges()) {
            is BridgeRegistryResult.Success -> bridges.value.firstOrNull { it.isActive }
            BridgeRegistryResult.Corrupt -> return RestoredState.Unavailable
            is BridgeRegistryResult.Failure -> return RestoredState.Unavailable
        } ?: return RestoredState.Unpaired

        val token = withContext(ioDispatcher) { credentialStore.loadApiToken(active.bridgeId) }
        return when (token) {
            is BridgeSecretResult.Present -> RestoredState.Paired(active)
            BridgeSecretResult.Absent -> RestoredState.NeedsRepair(active)
            is BridgeSecretResult.Failure -> RestoredState.NeedsRepair(active)
        }
    }

    /**
     * Startup classification of EVERY persisted record (multi-bridge; additive to [restore]).
     * Classify-only: a record with a readable token is `paired`; one whose token is missing or
     * unreadable is `needsRepair`; corrupt/unreadable metadata sets `metadataUnavailable`. This
     * method never deletes a credential or a record and never touches the network.
     */
    suspend fun restoreAll(): RestoredHome {
        val records = when (val bridges = bridgeRegistry.bridges()) {
            is BridgeRegistryResult.Success -> bridges.value
            BridgeRegistryResult.Corrupt -> return RestoredHome(emptyList(), emptyList(), metadataUnavailable = true)
            is BridgeRegistryResult.Failure -> return RestoredHome(emptyList(), emptyList(), metadataUnavailable = true)
        }
        val paired = mutableListOf<PairedBridgeRecord>()
        val needsRepair = mutableListOf<PairedBridgeRecord>()
        for (record in records) {
            val token = withContext(ioDispatcher) {
                try {
                    credentialStore.loadApiToken(record.bridgeId)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: RuntimeException) {
                    BridgeSecretResult.Failure(failure)
                }
            }
            when (token) {
                is BridgeSecretResult.Present -> paired += record
                BridgeSecretResult.Absent -> needsRepair += record
                is BridgeSecretResult.Failure -> needsRepair += record
            }
        }
        return RestoredHome(paired = paired, needsRepair = needsRepair, metadataUnavailable = false)
    }

    /** Result of [restoreAll]. Secret-free: records only. */
    data class RestoredHome(
        val paired: List<PairedBridgeRecord>,
        val needsRepair: List<PairedBridgeRecord>,
        val metadataUnavailable: Boolean,
    ) {
        val isEmpty: Boolean get() = paired.isEmpty() && needsRepair.isEmpty() && !metadataUnavailable
    }

    /**
     * Local-only forget: delete the Keystore token, then remove the metadata record. Idempotent and
     * retryable; a failed step yields [ForgetResult.CleanupFailed]. This does NOT revoke the
     * application key on the bridge — remote revocation is a later authenticated-REST concern.
     */
    suspend fun forget(bridgeId: String): ForgetResult {
        val tokenDeleted = withContext(ioDispatcher) {
            runCatching { credentialStore.deleteApiToken(bridgeId) }.isSuccess
        }
        if (!tokenDeleted) {
            return ForgetResult.CleanupFailed
        }
        return when (bridgeRegistry.remove(bridgeId)) {
            is BridgeRegistryResult.Success -> ForgetResult.Forgotten
            else -> ForgetResult.CleanupFailed
        }
    }

    /**
     * Explicit, user-authorised local reset of the bridge METADATA store for the
     * [RestoredState.Unavailable] case, where no bridge id is readable and so [forget] has no
     * target. Metadata only: no credential is touched. Any token left behind is inert (nothing
     * references it) and is overwritten by the next successful pairing of the same bridge.
     */
    suspend fun resetMetadata(): ForgetResult =
        when (bridgeRegistry.clear()) {
            is BridgeRegistryResult.Success -> ForgetResult.Forgotten
            else -> ForgetResult.CleanupFailed
        }

    private fun activeRecord(bridgeId: String, endpoint: BridgeEndpoint): PairedBridgeRecord =
        PairedBridgeRecord(
            bridgeId = bridgeId,
            name = endpoint.name,
            host = endpoint.host,
            port = endpoint.port,
            isActive = true,
        )

    private fun PairingFailureReason.toErrorReason(): PairingErrorReason =
        when (this) {
            PairingFailureReason.InvalidRequest -> PairingErrorReason.INVALID_REQUEST
            PairingFailureReason.IdentityMismatch -> PairingErrorReason.IDENTITY_MISMATCH
            PairingFailureReason.UnverifiableLeafIdentity -> PairingErrorReason.IDENTITY_MISMATCH
            PairingFailureReason.TransportError -> PairingErrorReason.UNTRUSTED_OR_UNREACHABLE
            is PairingFailureReason.BridgeError -> PairingErrorReason.BRIDGE_ERROR
            is PairingFailureReason.MalformedResponse -> PairingErrorReason.BRIDGE_RESPONSE_INVALID
            is PairingFailureReason.ResponseTooLarge -> PairingErrorReason.BRIDGE_RESPONSE_INVALID
            is PairingFailureReason.UnexpectedHttpStatus -> PairingErrorReason.BRIDGE_RESPONSE_INVALID
        }

    companion object {
        /** The fixed, accepted HTTPS pairing port for Batch 4 (D-015 / contract). */
        const val PAIRING_PORT: Int = 443
    }
}
