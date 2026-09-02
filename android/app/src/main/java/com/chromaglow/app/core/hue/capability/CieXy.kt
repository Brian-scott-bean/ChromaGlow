package com.chromaglow.app.core.hue.capability

/** A CIE 1931 chromaticity point as the bridge expresses it. Both coordinates are in [0, 1]. */
data class CieXy(val x: Double, val y: Double) {
    init {
        require(x in 0.0..1.0 && y in 0.0..1.0) { "xy must lie in [0,1]" }
    }
}
