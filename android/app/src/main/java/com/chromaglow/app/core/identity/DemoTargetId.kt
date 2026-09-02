package com.chromaglow.app.core.identity

/**
 * Identity for demo-mode targets. A separate domain from [BridgeId]/[ResourceKey] by
 * construction: the demo "bridge" segment is REQUIRED to fail the canonical physical-id shape, so
 * demo state can never be mistaken for, or keyed alongside, a real Hue bridge.
 */
data class DemoTargetId(
    val demoBridge: String,
    val id: String,
) {
    init {
        require(demoBridge.isNotBlank()) { "demoBridge must not be blank" }
        require(id.isNotBlank()) { "id must not be blank" }
        require(!BridgeId.CANONICAL.matches(demoBridge)) {
            "a demo identity must never look like a physical Hue bridge id"
        }
    }
}
