package com.chromaglow.app.ui.components

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

const val MODE_SEGMENT_TAG: String = "mode_segment"

fun modeSegmentTag(id: String): String = "${MODE_SEGMENT_TAG}_$id"

data class SegmentOption(val id: String, val label: String)

/**
 * One segmented control for mutually exclusive modes (Colour · Warmth). 48 dp tall; each segment
 * carries the platform's `selected` semantics. Never rendered with a single option — callers
 * skip it when only one mode exists.
 */
@Composable
fun ModeSegment(
    options: List<SegmentOption>,
    selectedId: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    SingleChoiceSegmentedButtonRow(
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .testTag(MODE_SEGMENT_TAG),
    ) {
        options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option.id == selectedId,
                onClick = { if (enabled) onSelect(option.id) },
                enabled = enabled,
                shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
                colors = SegmentedButtonDefaults.colors(
                    activeContainerColor = MaterialTheme.colorScheme.primaryContainer,
                    activeContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                ),
                modifier = Modifier.testTag(modeSegmentTag(option.id)),
            ) {
                Text(text = option.label)
            }
        }
    }
}
