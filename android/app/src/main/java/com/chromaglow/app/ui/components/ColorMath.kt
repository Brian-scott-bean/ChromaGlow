package com.chromaglow.app.ui.components

import androidx.compose.ui.graphics.Color
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import kotlin.math.pow

/**
 * Pure colour helpers for rendering and for keeping every outbound xy inside the lamp's own
 * gamut. UI-only: the coordinator re-validates; this exists so the pad never even proposes an
 * unreachable point.
 */
object ColorMath {

    /** A user-facing named colour. xy values are approximate sRGB primaries in CIE 1931. */
    data class NamedColor(val name: String, val xy: CieXy)

    /** Named colours offered beside the pad so colour is reachable without a 2-D gesture. */
    val NAMED: List<NamedColor> = listOf(
        NamedColor("Warm white", CieXy(0.4578, 0.4101)),
        NamedColor("Cool white", CieXy(0.3127, 0.3290)),
        NamedColor("Red", CieXy(0.6400, 0.3300)),
        NamedColor("Orange", CieXy(0.5614, 0.4156)),
        NamedColor("Yellow", CieXy(0.4325, 0.5007)),
        NamedColor("Green", CieXy(0.3000, 0.6000)),
        NamedColor("Cyan", CieXy(0.2247, 0.3287)),
        NamedColor("Blue", CieXy(0.1500, 0.0600)),
        NamedColor("Purple", CieXy(0.2725, 0.1096)),
        NamedColor("Pink", CieXy(0.3824, 0.1601)),
    )

    /** Closest point inside [gamut] to [xy] (identity when already inside). */
    fun clampToGamut(xy: CieXy, gamut: Gamut): CieXy {
        val r = gamut.red
        val g = gamut.green
        val b = gamut.blue
        if (inside(xy, r, g, b)) return xy
        val candidates = listOf(closestOnSegment(xy, r, g), closestOnSegment(xy, g, b), closestOnSegment(xy, b, r))
        return candidates.minBy { dist2(it, xy) }
    }

    fun inside(p: CieXy, a: CieXy, b: CieXy, c: CieXy): Boolean {
        val d1 = sign(p, a, b)
        val d2 = sign(p, b, c)
        val d3 = sign(p, c, a)
        val hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        val hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    private fun sign(p: CieXy, a: CieXy, b: CieXy): Double =
        (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)

    private fun closestOnSegment(p: CieXy, a: CieXy, b: CieXy): CieXy {
        val abx = b.x - a.x
        val aby = b.y - a.y
        val len2 = abx * abx + aby * aby
        val t = if (len2 == 0.0) 0.0 else (((p.x - a.x) * abx + (p.y - a.y) * aby) / len2).coerceIn(0.0, 1.0)
        return CieXy((a.x + t * abx).coerceIn(0.0, 1.0), (a.y + t * aby).coerceIn(0.0, 1.0))
    }

    private fun dist2(a: CieXy, b: CieXy): Double = (a.x - b.x).let { it * it } + (a.y - b.y).let { it * it }

    /** Display-only approximation of a chromaticity at full brightness, normalised so it is vivid. */
    fun toDisplayColor(xy: CieXy): Color {
        val y = if (xy.y <= 0.0001) 0.0001 else xy.y
        val bigY = 1.0
        val bigX = bigY / y * xy.x
        val bigZ = bigY / y * (1.0 - xy.x - xy.y)
        var r = bigX * 1.656492 - bigY * 0.354851 - bigZ * 0.255038
        var g = -bigX * 0.707196 + bigY * 1.655397 + bigZ * 0.036152
        var b = bigX * 0.051713 - bigY * 0.121364 + bigZ * 1.011530
        val max = maxOf(r, g, b, 1e-6)
        r /= max
        g /= max
        b /= max
        return Color(gamma(r).toFloat(), gamma(g).toFloat(), gamma(b).toFloat())
    }

    private fun gamma(v: Double): Double {
        val c = v.coerceIn(0.0, 1.0)
        return if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1.0 / 2.4) - 0.055
    }

    /** Approximate colour of a black body at [mirek] for display only. */
    fun mirekToDisplayColor(mirek: Int): Color {
        val kelvin = 1_000_000.0 / mirek.coerceAtLeast(1)
        val t = kelvin / 100.0
        val r = if (t <= 66) 255.0 else (329.698727446 * (t - 60).pow(-0.1332047592)).coerceIn(0.0, 255.0)
        val g = if (t <= 66) {
            (99.4708025861 * kotlin.math.ln(t) - 161.1195681661).coerceIn(0.0, 255.0)
        } else {
            (288.1221695283 * (t - 60).pow(-0.0755148492)).coerceIn(0.0, 255.0)
        }
        val b = when {
            t >= 66 -> 255.0
            t <= 19 -> 0.0
            else -> (138.5177312231 * kotlin.math.ln(t - 10) - 305.0447927307).coerceIn(0.0, 255.0)
        }
        return Color((r / 255).toFloat(), (g / 255).toFloat(), (b / 255).toFloat())
    }

    fun mirekToKelvinLabel(mirek: Int): String {
        val kelvin = (1_000_000.0 / mirek.coerceAtLeast(1)).toInt()
        val rounded = (kelvin + 25) / 50 * 50
        return "$rounded K"
    }
}
