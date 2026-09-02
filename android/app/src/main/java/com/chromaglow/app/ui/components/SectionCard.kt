package com.chromaglow.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp

fun sectionTag(id: String): String = "section_$id"
fun checkingTag(id: String): String = "checking_$id"

/** Staged-but-honest opacity for a CHECKING placeholder (iOS `stagedOpacity`). */
private const val CHECKING_ALPHA = 0.7f

/**
 * A titled disclosure on Light detail. [footnote] carries the hardware-unverified caveat when
 * the control is Known but unproven on these lamps.
 */
@Composable
fun SectionCard(
    id: String,
    title: String,
    modifier: Modifier = Modifier,
    footnote: String? = null,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag(sectionTag(id)),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier
                        .weight(1f)
                        .semantics { heading() },
                )
                trailing?.invoke()
            }
            content()
            footnote?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * The CHECKING state: a quiet, NON-INTERACTIVE placeholder for a capability whose evidence is
 * UNKNOWN or UNREADABLE. It never says "unsupported", exposes no click or progress action, and
 * announces itself as "Checking".
 */
@Composable
fun CheckingPlaceholder(
    id: String,
    title: String,
    modifier: Modifier = Modifier,
    detail: String = "Checking what this light can do…",
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .alpha(CHECKING_ALPHA)
            .testTag(checkingTag(id))
            .semantics(mergeDescendants = true) {
                contentDescription = "$title. $detail"
                stateDescription = "Checking"
            },
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
