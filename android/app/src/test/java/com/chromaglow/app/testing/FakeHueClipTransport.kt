package com.chromaglow.app.testing

import com.chromaglow.app.core.hue.rest.ClipDocument
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.hue.rest.ClipResult
import com.chromaglow.app.core.hue.rest.ClipWriteBody
import com.chromaglow.app.core.hue.rest.HueClipClient
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** One recorded wire event on the fake transport. */
data class WireRecord(
    val method: String,
    val type: ResourceType,
    val id: ResourceId?,
    val body: JsonObject?,
    /** Monotonic virtual-time stamp supplied by the test (null when not injected). */
    val atMillis: Long?,
)

/**
 * Deterministic in-memory [HueClipClient] for session/coordinator tests: every call is recorded
 * with its exact body, and responses are scripted per (method, type, id) either immediately or
 * through a [CompletableDeferred] so a test can hold a PUT in flight and release it later.
 * No threads, no network, no clock of its own.
 */
class FakeHueClipTransport(
    override val bridgeId: BridgeId,
    private val now: () -> Long? = { null },
) : HueClipClient {

    val wire = mutableListOf<WireRecord>()

    /** Responses for GET collection by type. */
    val collections = mutableMapOf<ResourceType, ClipResult<ClipDocument>>()

    /** Responses for GET single resource. */
    val singles = mutableMapOf<Pair<ResourceType, ResourceId>, ClipResult<ClipDocument>>()

    /** Default answer for any PUT not held; Ok(empty) unless a test changes it. */
    var putResult: ClipResult<ClipDocument> = ClipResult.Ok(ClipDocument(emptyList()))

    /** Queue of deferred PUT gates; when non-empty, the next PUT suspends until its gate completes. */
    val heldPuts = ArrayDeque<CompletableDeferred<ClipResult<ClipDocument>>>()

    /** Optional per-call override for PUTs keyed by (type,id). */
    val putResults = mutableMapOf<Pair<ResourceType, ResourceId>, ClipResult<ClipDocument>>()

    var getCount = 0
    var putCount = 0

    /** When set, every GET suspends on it first (lets a test hold a load in flight). */
    var getGate: CompletableDeferred<Unit>? = null

    fun puts(): List<WireRecord> = wire.filter { it.method == "PUT" }

    fun putsTo(id: ResourceId): List<WireRecord> = puts().filter { it.id == id }

    /** Script a collection from raw CLIP JSON text (`{"data":[…]}`), as the bridge would send it. */
    fun collection(type: ResourceType, json: String) {
        val root = Json.parseToJsonElement(json).jsonObject
        val data = root["data"]?.jsonArray?.map { it.jsonObject } ?: emptyList()
        collections[type] = ClipResult.Ok(ClipDocument(data))
    }

    fun fail(type: ResourceType, error: ClipError) {
        collections[type] = ClipResult.Err(error)
    }

    /** Hold the next PUT; the returned deferred releases it with the given result. */
    fun holdNextPut(): CompletableDeferred<ClipResult<ClipDocument>> =
        CompletableDeferred<ClipResult<ClipDocument>>().also { heldPuts.addLast(it) }

    override suspend fun getResources(type: ResourceType): ClipResult<ClipDocument> {
        getCount++
        wire += WireRecord("GET", type, null, null, now())
        getGate?.await()
        return collections[type] ?: ClipResult.Ok(ClipDocument(emptyList()))
    }

    override suspend fun getResource(type: ResourceType, id: ResourceId): ClipResult<ClipDocument> {
        getCount++
        wire += WireRecord("GET", type, id, null, now())
        return singles[type to id] ?: ClipResult.Ok(ClipDocument(emptyList()))
    }

    override suspend fun putResource(type: ResourceType, id: ResourceId, body: ClipWriteBody): ClipResult<ClipDocument> {
        putCount++
        wire += WireRecord("PUT", type, id, body.json, now())
        val gate = heldPuts.removeFirstOrNull()
        if (gate != null) return gate.await()
        return putResults[type to id] ?: putResult
    }
}
