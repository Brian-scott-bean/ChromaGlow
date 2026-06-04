package com.chromaglow.app.core.hue.discovery

data class BridgeEndpoint(
    val name: String,
    val host: String,
    val port: Int,
) {
    init {
        require(name.isNotBlank())
        require(host.isNotBlank())
        require(port in 1..65535)
    }

    val endpointKey: String
        get() = "${host.lowercase()}:$port"

    val displayAddress: String
        get() = if (host.contains(":")) "[$host]:$port" else "$host:$port"
}
