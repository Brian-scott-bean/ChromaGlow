package com.chromaglow.app.core.hue.discovery

data class BridgeDiscoverySnapshot(
    val isScanning: Boolean,
    val choices: List<BridgeEndpoint>,
    val statusMessage: String? = null,
)

interface BridgeDiscoveryService {
    fun start(onSnapshot: (BridgeDiscoverySnapshot) -> Unit)
    fun stop()
}
