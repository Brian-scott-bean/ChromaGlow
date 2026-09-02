package com.chromaglow.app.core.identity

/**
 * A bare CLIP v2 resource id (UUID-shaped, bridge-scoped). It is NEVER a map key on its own:
 * the same id can exist on two bridges. Always pair it with a [BridgeId] via [ResourceKey].
 */
@JvmInline
value class ResourceId(val value: String) {
    init {
        require(value.isNotBlank()) { "ResourceId must not be blank" }
        require(value.none { it.isWhitespace() }) { "ResourceId must not contain whitespace" }
    }

    override fun toString(): String = value
}
