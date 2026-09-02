package com.chromaglow.app.testing

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.BridgeSnapshotCache
import com.chromaglow.app.core.session.CacheReadResult
import com.chromaglow.app.core.session.CacheWriteResult
import com.chromaglow.app.core.session.Freshness
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationCoordinator
import com.chromaglow.app.core.session.MutationOutcome
import com.chromaglow.app.core.session.MutationToken
import com.chromaglow.app.core.session.SessionAttachment
import com.chromaglow.app.core.session.SessionClock
import com.chromaglow.app.core.session.StaleReason

/** In-memory [BridgeSnapshotCache]; a hit is painted Stale FROM_CACHE exactly like the file cache. */
class FakeSnapshotCache(override val bridgeId: BridgeId) : BridgeSnapshotCache {
    var stored: BridgeSnapshot? = null
    var readResult: CacheReadResult? = null
    val writes = mutableListOf<BridgeSnapshot>()
    var clearCount = 0

    override suspend fun read(): CacheReadResult {
        readResult?.let { return it }
        val s = stored ?: return CacheReadResult.Miss
        return CacheReadResult.Hit(s.copy(freshness = Freshness.Stale(s.generation, StaleReason.FROM_CACHE)))
    }

    override suspend fun write(snapshot: BridgeSnapshot): CacheWriteResult {
        if (snapshot.bridgeId != bridgeId) return CacheWriteResult.Failed("wrong bridge")
        stored = snapshot
        writes += snapshot
        return CacheWriteResult.Written
    }

    override suspend fun clear() {
        clearCount++
        stored = null
    }
}

/** Records submissions; answers Accepted with increasing tokens unless [refuse] is set. */
class RecordingCoordinator : MutationCoordinator {
    val submitted = mutableListOf<LiveMutation>()
    var refuse: MutationOutcome.Refused? = null
    private var next = 1L

    override suspend fun submit(mutation: LiveMutation): MutationOutcome {
        submitted += mutation
        refuse?.let { return it }
        return MutationOutcome.Accepted(MutationToken(next++))
    }
}

class RecordingAttachment : SessionAttachment {
    val events = mutableListOf<String>()
    override fun onForeground() { events += "foreground" }
    override fun onBackground() { events += "background" }
    override fun close() { events += "close" }
}

/** A test clock the test advances by hand. */
class ManualClock(start: Long = 1_000_000L) : SessionClock {
    var now: Long = start
    override fun nowMillis(): Long = now
    fun advance(millis: Long) { now += millis }
}
