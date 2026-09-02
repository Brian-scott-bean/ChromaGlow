package com.chromaglow.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

data class ChipOption(
    val id: String,
    val label: String,
    val swatch: Color? = null,
)

fun chipTag(rowTag: String, id: String): String = "${rowTag}_chip_$id"

/**
 * Single-choice chip row. Each chip is ≥ 48 dp tall, carries `selected` semantics, and refuses
 * clicks when [enabled] is false. Horizontal scroll keeps long effect lists reachable at 200 %.
 */
@Composable
fun ChoiceChipRow(
    options: List<ChipOption>,
    selectedId: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    rowTag: String = "chips",
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .testTag(rowTag),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { option ->
            val selected = option.id == selectedId
            FilterChip(
                selected = selected,
                onClick = { if (enabled) onSelect(option.id) },
                enabled = enabled,
                label = { Text(text = option.label) },
                leadingIcon = option.swatch?.let { color ->
                    {
                        Box(
                            modifier = Modifier
                                .size(16.dp)
                                .background(color, CircleShape)
                                .border(1.dp, MaterialTheme.colorScheme.outline, CircleShape),
                        )
                    }
                },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                ),
                modifier = Modifier
                    .height(48.dp)
                    .testTag(chipTag(rowTag, option.id))
                    .semantics { contentDescription = option.label },
            )
        }
    }
}
