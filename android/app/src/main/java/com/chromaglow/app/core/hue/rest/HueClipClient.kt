package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.serialization.json.JsonObject

/** A decoded CLIP v2 envelope: the `data` array elements plus any `errors[]` descriptions. */
data class ClipDocument(
    val data: List<JsonObject>,
    val errors: List<String> = emptyList(),
)

/** A pure JSON write body produced by the (later) body builders. Never built in feature code. */
data class ClipWriteBody(val json: JsonObject)

/**
 * Authenticated CLIP v2 transport for exactly ONE bridge. Credentials are supplied at construction
 * by the session layer and are never exposed to callers. Pinned to [bridgeId] at the TLS layer
 * (leaf CN == bridgeId) on every call. No retry policy lives here or in feature code.
 *
 * ARCHITECTURAL BOUNDARY: [putResource] is the only outbound mutation primitive, and the only
 * production caller allowed is the session's MutationCoordinator. Feature/UI/ViewModel code must
 * not reference this interface at all (enforced by ArchitectureBoundaryTest).
 */
interface HueClipClient {
    val bridgeId: BridgeId

    suspend fun getResources(type: ResourceType): ClipResult<ClipDocument>

    suspend fun getResource(type: ResourceType, id: ResourceId): ClipResult<ClipDocument>

    suspend fun putResource(type: ResourceType, id: ResourceId, body: ClipWriteBody): ClipResult<ClipDocument>
}
