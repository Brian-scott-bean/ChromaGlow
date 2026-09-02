package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.rest.wire.ClipResourceCodec
import com.chromaglow.app.core.hue.tls.BridgeLeafIdentity
import com.chromaglow.app.core.identity.ResourceType

/**
 * Outcome of the defense-in-depth bridge identity probe. Diagnostic only: NOT a fail-closed
 * prerequisite (the TLS leaf CN is the authority). Secret-free; the observed id is a bridge id,
 * not a credential.
 */
sealed interface BridgeProbeResult {
    data object Match : BridgeProbeResult

    /** `bridge_id` parsed as a canonical id but differs from the pinned one. */
    data class Mismatch(val observed: String) : BridgeProbeResult

    /** Field absent, not 16-hex, or the element could not be decoded. */
    data class Malformed(val reason: String) : BridgeProbeResult

    data class Unavailable(val error: ClipError) : BridgeProbeResult
}

/**
 * `GET /clip/v2/resource/bridge`, compared to the client's pinned [com.chromaglow.app.core.identity.BridgeId].
 * The session records the (redacted) result in diagnostics; it never revokes, refuses, or
 * touches credentials on any outcome.
 */
class BridgeIdentityProbe(private val client: HueClipClient) {

    suspend fun probe(): BridgeProbeResult {
        val document = when (val result = client.getResources(ResourceType.BRIDGE)) {
            is ClipResult.Ok -> result.value
            is ClipResult.Err -> return BridgeProbeResult.Unavailable(result.error)
        }
        val element = document.data.firstOrNull() ?: return BridgeProbeResult.Malformed("no bridge element")
        val bridge = ClipResourceCodec.bridge(element) ?: return BridgeProbeResult.Malformed("bridge element unreadable")
        val raw = bridge.bridgeId ?: return BridgeProbeResult.Malformed("bridge_id absent")
        val observed = BridgeLeafIdentity.canonicalize(raw) ?: return BridgeProbeResult.Malformed("bridge_id not 16-hex")
        return if (observed == client.bridgeId) BridgeProbeResult.Match else BridgeProbeResult.Mismatch(observed.value)
    }
}
