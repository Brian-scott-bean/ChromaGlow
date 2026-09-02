package com.chromaglow.app.feature.setup

import com.chromaglow.app.core.bridge.BridgeRegistry
import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.discovery.BridgeDiscoverySnapshot
import com.chromaglow.app.core.hue.discovery.BridgeDiscoveryService
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.transport.HuePairingClient
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import java.util.concurrent.CountDownLatch

/**
 * In-memory fakes used by the Setup Compose tests so they exercise real pairing-state transitions
 * (through the real [com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow]) without ever
 * contacting a bridge or building a real DataStore/Keystore.
 */

class FakeHuePairingClient(
    var result: HuePairingResult,
    private val gate: CountDownLatch? = null,
) : HuePairingClient {
    @Volatile
    var lastEndpoint: BridgeEndpoint? = null

    override fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String?): HuePairingResult {
        lastEndpoint = endpoint
        gate?.await()
        return result
    }
}

class FakeCredentialStore : BridgeCredentialStore {
    val tokens = mutableMapOf<String, String>()

    override fun saveApiToken(bridgeId: String, token: String) {
        tokens[bridgeId] = token
    }

    override fun loadApiToken(bridgeId: String): BridgeSecretResult {
        val token = tokens[bridgeId]
        return if (token != null) BridgeSecretResult.Present(token) else BridgeSecretResult.Absent
    }

    override fun deleteApiToken(bridgeId: String) {
        tokens.remove(bridgeId)
    }
}

class FakeBridgeRegistry : BridgeRegistry {
    val records = mutableListOf<PairedBridgeRecord>()

    /** When set, [bridges] returns this instead of the record list (e.g. to simulate Corrupt). */
    var readResult: BridgeRegistryResult<List<PairedBridgeRecord>>? = null

    override suspend fun bridges(): BridgeRegistryResult<List<PairedBridgeRecord>> =
        readResult ?: BridgeRegistryResult.Success(records.toList())

    override suspend fun upsert(record: PairedBridgeRecord): BridgeRegistryResult<Unit> {
        records.removeAll { it.bridgeId == record.bridgeId }
        records.add(record)
        return BridgeRegistryResult.Success(Unit)
    }

    override suspend fun remove(bridgeId: String): BridgeRegistryResult<Unit> {
        records.removeAll { it.bridgeId == bridgeId }
        return BridgeRegistryResult.Success(Unit)
    }

    override suspend fun clear(): BridgeRegistryResult<Unit> {
        records.clear()
        readResult = null
        return BridgeRegistryResult.Success(Unit)
    }
}

class FakeBridgeDiscoveryService : BridgeDiscoveryService {
    private var callback: ((BridgeDiscoverySnapshot) -> Unit)? = null
    var startCount = 0
    var stopCount = 0

    override fun start(onSnapshot: (BridgeDiscoverySnapshot) -> Unit) {
        startCount++
        callback = onSnapshot
    }

    override fun stop() {
        stopCount++
    }

    fun emit(snapshot: BridgeDiscoverySnapshot) {
        callback?.invoke(snapshot)
    }
}
