package com.chromaglow.app.core.hue.pairing.transport

import com.chromaglow.app.core.hue.discovery.BridgeEndpoint

/**
 * Boundary for performing Hue link-button pairing against a single discovered bridge over a
 * pinned, CA-validated, identity-checked TLS channel.
 *
 * Implementations enforce the full security contract: HTTPS only, no redirect following, no
 * automatic retry of the create-user POST, a bounded (64 KiB) response body, and a verified leaf
 * identity that must agree with the bridge's advertised `bridgeid` (and any supplied hint). The
 * boundary never throws for an expected failure — every outcome is a typed [HuePairingResult]
 * (fail closed). Calls are synchronous/blocking and must not be made on a UI thread.
 */
interface HuePairingClient {

    /**
     * Probe the bridge's identity, then request an application key.
     *
     * The implementation first performs `GET /api/0/config`, authenticates the bridge from the
     * CA-validated leaf certificate's Common Name, and requires both the config `bridgeid` and
     * any [expectedBridgeId] hint to match that identity case-insensitively. Only on a full match
     * does it perform `POST /api`; any mismatch fails closed WITHOUT issuing the POST.
     *
     * @param endpoint the routing target (host/port) for the bridge; used to build URLs only.
     * @param expectedBridgeId optional 16-hex `bridgeid` hint to pin the expected identity. When
     *   supplied it is enforced both at the TLS layer and against the authenticated leaf identity.
     * @return a typed outcome; [HuePairingResult.LinkButtonNotPressed] is the only retryable case.
     */
    fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String? = null): HuePairingResult
}
