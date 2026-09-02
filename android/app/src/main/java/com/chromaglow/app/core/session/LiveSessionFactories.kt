package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.rest.OkHttpHueClipClient
import com.chromaglow.app.core.hue.sse.OkHttpEventStreamSource
import com.chromaglow.app.core.hue.tls.HueTrust
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import java.io.File

/**
 * Production composition of the per-bridge collaborators. The app shell owns the call site; this
 * keeps every transport/TLS/cache decision inside core/session so no feature code ever sees them.
 */
object LiveSessionFactories {
    fun production(
        trust: HueTrust,
        cacheDirectory: File,
        register: EffectSafetyRegister = DefaultEffectSafetyRegister,
    ): LiveHomeFactories = LiveHomeFactories(
        transport = { record, bridgeId, keys ->
            OkHttpHueClipClient(bridgeId = bridgeId, host = record.host, port = record.port, keys = keys, tls = trust.forBridge(bridgeId))
        },
        cache = { bridgeId -> FileBridgeSnapshotCache(bridgeId, cacheDirectory) },
        coordinator = { env -> DefaultMutationCoordinator(env, register = register) },
        attachments = listOf { env, record, keys ->
            EventStreamRunner(
                env = env,
                source = OkHttpEventStreamSource(bridgeId = env.bridgeId, host = record.host, port = record.port, keys = keys, tls = trust.forBridge(env.bridgeId)),
                authority = env.authority,
            )
        },
    )
}
