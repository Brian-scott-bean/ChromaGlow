package com.chromaglow.app.core.model

data class LightDisplayModel(
    val id: String,
    val name: String,
    val isOn: Boolean,
    val brightness: Int,
    val roomId: String,
    val bridgeId: String,
) {
    init {
        require(id.isNotBlank())
        require(name.isNotBlank())
        require(brightness in 1..100)
        require(roomId.isNotBlank())
        require(bridgeId.isNotBlank())
    }
}
