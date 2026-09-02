package com.chromaglow.app.feature.roomdetail

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.feature.home.GroupCardUi
import com.chromaglow.app.ui.components.ConnectionRowUi

/** Live Room/Zone detail: the group instrument, its member lights, and honest coverage lines. */
data class GroupDetailUiState(
    val found: Boolean,
    val group: GroupCardUi?,
    val lights: List<LightCardUi>,
    val coverage: List<String>,
    val strip: List<ConnectionRowUi>,
    /** Group colour instrument; null (hidden) when no member has colour KNOWN. */
    val groupColor: GroupInstrumentUi? = null,
    /** Group warmth instrument; null (hidden) when no member has CT KNOWN. */
    val groupWarmth: GroupInstrumentUi? = null,
)

/**
 * A group-level colour or warmth control. The coordinator fans the write out to the KNOWN
 * members only, so the caption states the reach honestly. The group range is the protocol clamp
 * (153–500 mirek) or a neutral display gamut; neither is presented as a lamp's KNOWN schema.
 */
data class GroupInstrumentUi(
    val capableCount: Int,
    val total: Int,
) {
    val caption: String
        get() = if (capableCount == total) {
            if (total == 1) "Applies to the 1 light" else "Applies to all $total lights"
        } else {
            "Applies to $capableCount of $total lights"
        }
}

/** One member light as the compact card renders it. Colour is carried as truth (xy/mirek), not paint. */
data class LightCardUi(
    val key: ResourceKey,
    val name: String,
    val isOn: Boolean,
    val brightness: Int?,
    val colorXy: CieXy?,
    val mirek: Int?,
    val knownGlyphs: List<String>,
    val controlsEnabled: Boolean,
    val disabledReason: String?,
) {
    val target: TargetRef.Live get() = TargetRef.Live(key)
    val composeKey: String get() = key.composeKey

    val statusLine: String
        get() = buildString {
            append(if (isOn) "On" else "Off")
            if (brightness != null) append(" · $brightness%")
        }
}
