package com.chromaglow.app.core.identity

/**
 * THE identity of a live Hue resource: bridge-qualified by construction. Every authoritative map,
 * cache entry, mutation, SSE reduction, and navigation argument uses this type, so identical
 * resource ids on two bridges can never collide.
 */
data class ResourceKey(
    val bridgeId: BridgeId,
    val type: ResourceType,
    val id: ResourceId,
) {
    /** Stable, collision-free string for Compose keys and cache file names. */
    val composeKey: String
        get() = "${bridgeId.value}:${type.wireName}:${id.value}"

    override fun toString(): String = composeKey
}
