package com.chromaglow.app.core.hue.discovery

data class BridgeEndpoint(
    val name: String,
    val host: String,
    val port: Int,
) {
    init {
        require(name.isNotBlank())
        require(host.isNotBlank())
        // An IPv6 zone id ("fe80::1%wlan0") is not a routable URL host: OkHttp rejects it with an
        // IllegalArgumentException far from the discovery boundary (audit L-38). Refuse it here so
        // no endpoint carrying one can ever reach the transport.
        require(!host.contains('%'))
        require(host.none { it.isWhitespace() })
        require(port in 1..65535)
    }

    val endpointKey: String
        get() = "${host.lowercase()}:$port"

    val displayAddress: String
        get() = if (host.contains(":")) "[$host]:$port" else "$host:$port"
}
