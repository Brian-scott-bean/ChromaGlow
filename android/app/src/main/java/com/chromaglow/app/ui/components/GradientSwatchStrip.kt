package com.chromaglow.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.hue.capability.CieXy

const val GRADIENT_STRIP_TAG: String = "gradient_strip"

fun gradientSwatchTag(index: Int): String = "gradient_swatch_$index"

/**
 * Exactly `points.size` swatches (the lamp's own cap, never a constant), one selected for editing.
 * Each swatch is a 48 dp radio-role target with a spoken position; editing happens through the
 * shared colour pad/chips the caller renders for the selected point.
 */
@Composable
fun GradientSwatchStrip(
    points: List<CieXy>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .testTag(GRADIENT_STRIP_TAG),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        points.forEachIndexed { index, xy ->
            val selected = index == selectedIndex
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
                    .testTag(gradientSwatchTag(index))
                    .selectable(
                        selected = selected,
                        enabled = enabled,
                        role = Role.RadioButton,
                        onClick = { onSelect(index) },
                    )
                    .semantics { contentDescription = "Gradient point ${index + 1} of ${points.size}" }
                    .background(
                        ColorMath.toDisplayColor(xy).copy(alpha = if (enabled) 1f else 0.4f),
                        RoundedCornerShape(10.dp),
                    )
                    .border(
                        width = if (selected) 3.dp else 1.dp,
                        color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline,
                        shape = RoundedCornerShape(10.dp),
                    ),
            )
        }
    }
}

/** A single flat swatch used inside light cards for the current colour. */
@Composable
fun ColorDot(color: Color?, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(color ?: MaterialTheme.colorScheme.outline, RoundedCornerShape(50))
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(50)),
    )
}
