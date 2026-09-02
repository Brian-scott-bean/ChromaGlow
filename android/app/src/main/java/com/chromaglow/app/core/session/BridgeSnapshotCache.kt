package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.BridgeId

/** Outcome of reading the cache. A damaged or unknown-version file is [Discarded], never fatal. */
sealed interface CacheReadResult {
    data class Hit(val snapshot: BridgeSnapshot) : CacheReadResult
    data object Miss : CacheReadResult
    data class Discarded(val reason: String) : CacheReadResult
}

sealed interface CacheWriteResult {
    data object Written : CacheWriteResult
    data class Failed(val reason: String) : CacheWriteResult
}

/**
 * Persisted last-known [BridgeSnapshot] for exactly ONE bridge, owned by its BridgeSession and
 * never by Compose. Contract:
 *  - keyed by [bridgeId]; a snapshot for another bridge is refused
 *  - versioned envelope ([FORMAT_VERSION]); unknown version → [CacheReadResult.Discarded]
 *  - secret-free: it persists a [BridgeSnapshot], which carries no credential by construction
 *  - atomic write (temp file + rename); corruption is discardable and nonfatal
 *  - a hit is painted as [Freshness.Stale] with [StaleReason.FROM_CACHE] until the network answers
 *  - an authoritative reload replaces the file; resources absent from it disappear
 */
interface BridgeSnapshotCache {
    val bridgeId: BridgeId

    suspend fun read(): CacheReadResult

    suspend fun write(snapshot: BridgeSnapshot): CacheWriteResult

    suspend fun clear()

    companion object {
        const val FORMAT_VERSION: Int = 1
    }
}
