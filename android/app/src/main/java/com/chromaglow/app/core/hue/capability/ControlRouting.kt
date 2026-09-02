package com.chromaglow.app.core.hue.capability

/** How a control aimed at a group (room/zone) reaches the lamps. */
enum class RoutingClass {
    /** One grouped_light (or scene) write; the bridge applies it. */
    GROUP_NATIVE,

    /** Fan out only to member lights whose capability is Known, paced; "N of M" coverage. */
    SUBSET_PER_LIGHT,

    /** Offered on the group only when every member light is capable; otherwise not offered. */
    ALL_OR_NOTHING,

    /** Never a group control; only addressable on an individual light. */
    PER_LIGHT_ONLY,
}

/** The controls the approved slice exposes on groups and lights. No signaling entry by design. */
enum class ControlKind {
    POWER,
    BRIGHTNESS,
    COLOR,
    COLOR_TEMPERATURE,
    FIRMWARE_EFFECT,
    TIMED_EFFECT,
    GRADIENT,
    SCENE_RECALL,
}

/** The approved, pinned routing map (plan §11). Changing a row is a product decision. */
object ControlRouting {
    fun classOf(kind: ControlKind): RoutingClass = when (kind) {
        ControlKind.POWER -> RoutingClass.GROUP_NATIVE
        ControlKind.BRIGHTNESS -> RoutingClass.GROUP_NATIVE
        ControlKind.COLOR -> RoutingClass.SUBSET_PER_LIGHT
        ControlKind.COLOR_TEMPERATURE -> RoutingClass.SUBSET_PER_LIGHT
        ControlKind.FIRMWARE_EFFECT -> RoutingClass.SUBSET_PER_LIGHT
        ControlKind.TIMED_EFFECT -> RoutingClass.ALL_OR_NOTHING
        ControlKind.GRADIENT -> RoutingClass.PER_LIGHT_ONLY
        ControlKind.SCENE_RECALL -> RoutingClass.GROUP_NATIVE
    }
}
