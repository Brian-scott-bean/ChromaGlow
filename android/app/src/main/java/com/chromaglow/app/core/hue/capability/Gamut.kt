package com.chromaglow.app.core.hue.capability

/** Where a gamut triangle came from. Rendering copy must be honest about it. */
enum class GamutSource {
    /** The bridge published `color.gamut` for this lamp: authoritative. */
    BRIDGE,

    /** Derived from `color.gamut_type` (A/B/C) via the published Hue specification. */
    SPEC_DERIVED,
}

/** Hue `gamut_type` letters as published by the bridge. */
enum class GamutType { A, B, C }

/**
 * A colour gamut triangle with provenance. Resolution hierarchy (never from product names):
 *  1. bridge `color.gamut` triangle → [GamutSource.BRIDGE]
 *  2. `color.gamut_type` A/B/C → [GamutSource.SPEC_DERIVED] via [fromGamutType]
 *  3. neither → the capability is [Evidence.UNKNOWN]; there is no Gamut value.
 */
data class Gamut(
    val red: CieXy,
    val green: CieXy,
    val blue: CieXy,
    val source: GamutSource,
) {
    companion object {
        /** Published Hue gamut A/B/C primaries. */
        fun specDerived(type: GamutType): Gamut = when (type) {
            GamutType.A -> Gamut(CieXy(0.704, 0.296), CieXy(0.2151, 0.7106), CieXy(0.138, 0.08), GamutSource.SPEC_DERIVED)
            GamutType.B -> Gamut(CieXy(0.675, 0.322), CieXy(0.409, 0.518), CieXy(0.167, 0.04), GamutSource.SPEC_DERIVED)
            GamutType.C -> Gamut(CieXy(0.692, 0.308), CieXy(0.17, 0.7), CieXy(0.153, 0.048), GamutSource.SPEC_DERIVED)
        }

        /** Non-throwing: an unrecognised letter yields null (→ Unknown), never a guess. */
        fun fromGamutType(raw: String?): Gamut? {
            val type = when (raw?.trim()?.uppercase()) {
                "A" -> GamutType.A
                "B" -> GamutType.B
                "C" -> GamutType.C
                else -> return null
            }
            return specDerived(type)
        }

        fun fromBridge(red: CieXy, green: CieXy, blue: CieXy): Gamut =
            Gamut(red, green, blue, GamutSource.BRIDGE)
    }
}
