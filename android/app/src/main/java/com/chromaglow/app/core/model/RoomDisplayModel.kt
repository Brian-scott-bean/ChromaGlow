package com.chromaglow.app.core.model

data class RoomDisplayModel(
    val id: String,
    val name: String,
    val isOn: Boolean,
    val brightness: Int,
    val lightCount: Int,
    val bridgeId: String,
) {
    init {
        require(id.isNotBlank())
        require(name.isNotBlank())
        require(brightness in 1..100)
        require(lightCount >= 0)
        require(bridgeId.isNotBlank())
    }
}
