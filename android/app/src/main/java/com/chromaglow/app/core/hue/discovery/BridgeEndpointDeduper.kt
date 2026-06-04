package com.chromaglow.app.core.hue.discovery

object BridgeEndpointDeduper {
    fun deduplicate(endpoints: List<BridgeEndpoint>): List<BridgeEndpoint> =
        endpoints.distinctBy(BridgeEndpoint::endpointKey)
}
