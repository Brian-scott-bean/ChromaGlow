package com.chromaglow.app.core.identity

/** CLIP v2 resource types the live session addresses. Unknown wire types never become keys. */
enum class ResourceType(val wireName: String) {
    LIGHT("light"),
    ROOM("room"),
    ZONE("zone"),
    GROUPED_LIGHT("grouped_light"),
    SCENE("scene"),
    DEVICE("device"),
    BRIDGE("bridge"),
    ;

    companion object {
        fun fromWireName(raw: String): ResourceType? = entries.firstOrNull { it.wireName == raw }
    }
}
