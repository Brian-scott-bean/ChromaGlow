package com.chromaglow.app.ui.components

import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Whether motion should be reduced. True when the platform animator scale is zero (the user's
 * "Remove animations" accessibility setting) or when a test provides it explicitly.
 *
 * Every ChromaGlow animation (pulsing placeholders, fader fills, activation glows) reads this
 * local and renders its final state statically when it is true. There is no flashing content in
 * this slice by construction; this local keeps decorative motion honest as well.
 */
val LocalReduceMotion = compositionLocalOf { false }

/** Reads the platform animator scale once per composition. Falls back to "motion allowed". */
@Composable
fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        try {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            ) == 0f
        } catch (_: Exception) {
            false
        }
    }
}
