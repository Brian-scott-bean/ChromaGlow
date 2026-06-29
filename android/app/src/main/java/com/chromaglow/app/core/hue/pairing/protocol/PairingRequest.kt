package com.chromaglow.app.core.hue.pairing.protocol

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Builds the request body for the Hue "create user" (link-button pairing) call.
 *
 * The body intentionally carries ONLY `devicetype`. We never request an encrypted-stream
 * client key, so `generateclientkey` is deliberately absent and must never be emitted.
 */
object PairingRequest {

    /**
     * The fixed `devicetype` advertised to the bridge during pairing.
     *
     * Format follows Hue's `<application>#<device>` convention.
     */
    const val DEVICE_TYPE: String = "chromaglow#android"

    /**
     * Returns the exact JSON body to POST to `/api`.
     *
     * Always produces `{"devicetype":"chromaglow#android"}` and never includes
     * `generateclientkey` (or any other field).
     */
    fun createUserBody(): String =
        buildJsonObject {
            put("devicetype", DEVICE_TYPE)
        }.toString()
}
