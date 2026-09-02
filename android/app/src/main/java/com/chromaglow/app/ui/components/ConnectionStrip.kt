package com.chromaglow.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.chromaglow.app.ui.theme.NoirSuccess

const val CONNECTION_STRIP_TAG: String = "connection_strip"

fun connectionRowTag(bridgeLabel: String): String = "connection_row_$bridgeLabel"

/** A single bridge's connection line as the strip renders it. Pure UI data. */
data class ConnectionRowUi(
    val bridgeLabel: String,
    val statusText: String,
    val tone: ConnectionTone,
    val detail: String? = null,
)

enum class ConnectionTone { LIVE, WORKING, STALE, BLOCKED }

/**
 * Glass strip (alpha surface + hairline border, no blur) listing each bridge's connection truth.
 * The whole strip is one polite live region so TalkBack announces state changes without focus.
 * Status is always carried by words; the dot is decoration.
 */
@Composable
fun ConnectionStrip(
    rows: List<ConnectionRowUi>,
    modifier: Modifier = Modifier,
) {
    val summary = rows.joinToString(separator = ". ") { "${it.bridgeLabel}: ${it.statusText}" }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surface.copy(alpha = 0.72f),
                RoundedCornerShape(14.dp),
            )
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .testTag(CONNECTION_STRIP_TAG)
            .semantics(mergeDescendants = true) {
                liveRegion = LiveRegionMode.Polite
                contentDescription = summary
            },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        rows.forEach { row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(connectionRowTag(row.bridgeLabel)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .background(toneColor(row.tone), CircleShape),
                )
                Text(
                    text = row.bridgeLabel,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = row.statusText,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (row.tone == ConnectionTone.BLOCKED) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            row.detail?.let { detail ->
                Text(
                    text = detail,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 18.dp),
                )
            }
        }
    }
}

@Composable
private fun toneColor(tone: ConnectionTone): Color = when (tone) {
    ConnectionTone.LIVE -> NoirSuccess
    ConnectionTone.WORKING -> MaterialTheme.colorScheme.onSurfaceVariant
    ConnectionTone.STALE -> MaterialTheme.colorScheme.primary
    ConnectionTone.BLOCKED -> MaterialTheme.colorScheme.error
}
