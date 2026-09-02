package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.rest.ClipDocument
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.hue.rest.ClipResult
import com.chromaglow.app.core.hue.rest.HueClipClient
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.util.concurrent.atomic.AtomicLong

/** What one authoritative load produced. */
sealed interface LoadOutcome {
    data class Loaded(val snapshot: BridgeSnapshot) : LoadOutcome

    /** The bridge answered 401/403 to at least one collection: the ONLY path to Revoked. */
    data class Unauthorized(val status: Int) : LoadOutcome

    data class Failed(val error: ClipError) : LoadOutcome

    /** A newer load was minted while this one was in flight; its result is dropped. */
    data object Superseded : LoadOutcome
}

/**
 * Generation-fenced loader for ONE bridge. Each [load] mints a generation; the five collections
 * are fetched in parallel; the result is accepted only if no newer generation was minted in the
 * meantime and it is newer than the last accepted one. A stale result is [LoadOutcome.Superseded]
 * and never replaces the snapshot. The caller (BridgeSession) serialises calls to 1 in-flight +
 * 1 pending; this class guarantees correctness even if it did not.
 */
class BridgeLoader(private val transport: HueClipClient) {
    private val minted = AtomicLong(0)
    private val accepted = AtomicLong(0)

    val latestGeneration: Long get() = minted.get()
    val acceptedGeneration: Long get() = accepted.get()

    /** Mints the next generation. Exposed so tests can prove stale rejection deterministically. */
    fun mint(): Long = minted.incrementAndGet()

    /** Accepts [snapshot] iff its generation is the latest minted and newer than the last accepted. */
    fun accept(snapshot: BridgeSnapshot): Boolean {
        val gen = snapshot.generation
        if (gen != minted.get()) return false
        while (true) {
            val current = accepted.get()
            if (gen <= current) return false
            if (accepted.compareAndSet(current, gen)) return true
        }
    }

    suspend fun load(): LoadOutcome {
        val generation = mint()
        val fetched = coroutineScope {
            val rooms = async { transport.getResources(ResourceType.ROOM) }
            val zones = async { transport.getResources(ResourceType.ZONE) }
            val grouped = async { transport.getResources(ResourceType.GROUPED_LIGHT) }
            val lights = async { transport.getResources(ResourceType.LIGHT) }
            val scenes = async { transport.getResources(ResourceType.SCENE) }
            listOf(rooms.await(), zones.await(), grouped.await(), lights.await(), scenes.await())
        }
        // Unauthorized dominates every other failure (a revoked key must be recognised even when
        // another collection timed out); any other failure keeps the previous snapshot.
        fetched.firstNotNullOfOrNull { (it as? ClipResult.Err)?.error as? ClipError.Unauthorized }
            ?.let { return LoadOutcome.Unauthorized(it.status) }
        fetched.firstNotNullOfOrNull { (it as? ClipResult.Err)?.error }
            ?.let { return LoadOutcome.Failed(it) }
        val docs = fetched.map { (it as ClipResult.Ok<ClipDocument>).value }
        val snapshot = SnapshotBuilder.build(
            transport.bridgeId, generation,
            ClipCollections(rooms = docs[0], zones = docs[1], groupedLights = docs[2], lights = docs[3], scenes = docs[4]),
        )
        return if (accept(snapshot)) LoadOutcome.Loaded(snapshot) else LoadOutcome.Superseded
    }
}
