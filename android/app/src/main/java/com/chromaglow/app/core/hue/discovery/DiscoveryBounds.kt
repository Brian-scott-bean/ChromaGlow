package com.chromaglow.app.core.hue.discovery

/**
 * Resource bounds for LAN discovery (audit L-39): an mDNS flood must not grow the tracked-service
 * maps, the legacy resolve queue, or the published chooser without limit. A real home has a
 * handful of bridges; [MAX_TRACKED_SERVICES] leaves ample headroom while capping attacker-driven
 * growth. Pure Kotlin so the policy is unit-tested without NsdManager.
 */
internal object DiscoveryBounds {

    /** Maximum distinct services tracked, queued for resolve, or published as choices. */
    const val MAX_TRACKED_SERVICES: Int = 32

    /**
     * Whether a newly found service may be tracked. An already-tracked name is always admitted
     * (updates for known services must not be starved by the cap).
     */
    fun canTrack(trackedCount: Int, alreadyTracked: Boolean): Boolean =
        alreadyTracked || trackedCount < MAX_TRACKED_SERVICES

    /** Whether one more legacy resolve may be queued. */
    fun canQueue(queuedCount: Int): Boolean = queuedCount < MAX_TRACKED_SERVICES

    /** Bounds the published chooser rows, preserving discovery order. */
    fun boundedChoices(choices: List<BridgeEndpoint>): List<BridgeEndpoint> =
        if (choices.size <= MAX_TRACKED_SERVICES) choices else choices.take(MAX_TRACKED_SERVICES)
}
