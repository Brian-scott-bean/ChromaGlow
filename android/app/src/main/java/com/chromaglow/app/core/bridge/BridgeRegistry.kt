package com.chromaglow.app.core.bridge

/**
 * Typed outcome of a [BridgeRegistry] operation.
 *
 * Corruption and IO failure are surfaced explicitly so a caller can map them to a user-safe
 * recovery state instead of mistaking damaged or unreadable metadata for an authenticated session.
 * No variant carries a secret.
 */
sealed interface BridgeRegistryResult<out T> {

    /** The operation completed; [value] is the result (a record list for reads, `Unit` for writes). */
    data class Success<out T>(val value: T) : BridgeRegistryResult<T>

    /**
     * Stored metadata exists but could not be decoded into valid records (damaged DataStore file
     * or structurally invalid JSON). The caller must treat this as a recovery/forget state, never
     * as a paired session. Surfaced by reads only; writes are authoritative and overwrite.
     */
    data object Corrupt : BridgeRegistryResult<Nothing>

    /**
     * The underlying store could not be read or written (e.g. IO error). [cause] is non-secret
     * (a filesystem/IO throwable), never a credential.
     */
    data class Failure(val cause: Throwable) : BridgeRegistryResult<Nothing>
}

/**
 * Durable, list-ready store of non-secret [PairedBridgeRecord] routing metadata.
 *
 * Batch 4 surfaces one active bridge, but the API is intentionally list-ready (multi-bridge) so a
 * later batch can expose several without a contract change. The registry NEVER accepts, stores, or
 * returns the application key / username: secrets stay in
 * [com.chromaglow.app.core.credentials.BridgeCredentialStore]. Operations are suspend so the
 * backing IO never runs on the main thread.
 */
interface BridgeRegistry {

    /**
     * All persisted bridge records.
     *
     * @return [BridgeRegistryResult.Success] with the (possibly empty) list, [BridgeRegistryResult.Corrupt]
     *   when stored metadata cannot be decoded, or [BridgeRegistryResult.Failure] on an IO error.
     */
    suspend fun bridges(): BridgeRegistryResult<List<PairedBridgeRecord>>

    /**
     * Insert [record] or replace the existing record with the same [PairedBridgeRecord.bridgeId].
     *
     * Authoritative: a previously corrupt blob is discarded rather than blocking the write, so a
     * re-pair can always recover. Returns [BridgeRegistryResult.Success] or
     * [BridgeRegistryResult.Failure] on an IO error.
     */
    suspend fun upsert(record: PairedBridgeRecord): BridgeRegistryResult<Unit>

    /**
     * Remove the record whose [PairedBridgeRecord.bridgeId] equals [bridgeId].
     *
     * Idempotent and retryable: removing an absent id (or clearing corrupt metadata) still succeeds.
     * Returns [BridgeRegistryResult.Success] or [BridgeRegistryResult.Failure] on an IO error.
     */
    suspend fun remove(bridgeId: String): BridgeRegistryResult<Unit>

    /**
     * Remove every record, including metadata that could not be decoded at all. This is the
     * explicit, user-authorised local reset for an unreadable store; it touches NO credential —
     * secrets are never deleted by the registry. Idempotent and retryable.
     */
    suspend fun clear(): BridgeRegistryResult<Unit>
}
