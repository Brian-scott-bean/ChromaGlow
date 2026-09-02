package com.chromaglow.app.testing

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

/**
 * Deterministic JVM fakes shared by presentation-layer unit tests. No network, no Keystore, no
 * DataStore, no threads. (The androidTest source set carries its own copies for Compose tests.)
 */

class FakeHuePairingClient(var result: HuePairingResult) : HuePairingClient {
    var lastEndpoint: BridgeEndpoint? = null
    var callCount = 0

    override fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String?): HuePairingResult {
        callCount++
        lastEndpoint = endpoint
        return result
    }
}

class FakeCredentialStore : BridgeCredentialStore {
    val tokens = mutableMapOf<String, String>()
    var deleteCount = 0

    override fun saveApiToken(bridgeId: String, token: String) {
        tokens[bridgeId] = token
    }

    override fun loadApiToken(bridgeId: String): BridgeSecretResult {
        val token = tokens[bridgeId]
        return if (token != null) BridgeSecretResult.Present(token) else BridgeSecretResult.Absent
    }

    override fun deleteApiToken(bridgeId: String) {
        deleteCount++
        tokens.remove(bridgeId)
    }
}

class FakeBridgeRegistry : BridgeRegistry {
    val records = mutableListOf<PairedBridgeRecord>()
    var readResult: BridgeRegistryResult<List<PairedBridgeRecord>>? = null
    var failClear = false
    var clearCount = 0

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
        clearCount++
        if (failClear) return BridgeRegistryResult.Failure(java.io.IOException("clear failed"))
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
