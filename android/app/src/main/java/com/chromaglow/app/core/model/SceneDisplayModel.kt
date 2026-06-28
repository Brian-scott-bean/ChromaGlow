package com.chromaglow.app.core.model

data class SceneDisplayModel(
    val id: String,
    val name: String,
    val roomId: String,
    val brightness: Int,
    val bridgeId: String,
    val isActive: Boolean = false,
) {
    init {
        require(id.isNotBlank())
        require(name.isNotBlank())
        require(roomId.isNotBlank())
        require(brightness in 1..100)
        require(bridgeId.isNotBlank())
    }
}
