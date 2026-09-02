package com.chromaglow.app.app

enum class ChromaGlowDestination {
    /** Cold-start classification in progress; nothing is painted so Setup never flashes. */
    Booting,
    Setup,
    /** Live Home (rooms/zones). */
    Home,
    /** Live room/zone detail. */
    GroupDetail,
    /** Live light detail. */
    LightDetail,
    /** Demo dashboard. */
    Dashboard,
    /** Demo room detail. */
    RoomDetail,
    Scenes,
    Settings,
}
