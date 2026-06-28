package com.chromaglow.app.feature.scenes

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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.SceneDisplayModel

/** Prefix for the per-scene clickable row test tag. */
const val SCENE_ROW_TAG_PREFIX: String = "scene_row_"

/** Prefix for the per-scene active-indicator test tag (present only while active). */
const val SCENE_ACTIVE_INDICATOR_TAG_PREFIX: String = "scene_active_indicator_"

/** Stable test tag for the clickable row of the scene with [sceneId]. */
fun sceneRowTag(sceneId: String): String = SCENE_ROW_TAG_PREFIX + sceneId

/** Stable test tag for the active indicator of the scene with [sceneId]. */
fun sceneActiveIndicatorTag(sceneId: String): String = SCENE_ACTIVE_INDICATOR_TAG_PREFIX + sceneId

/**
 * Stateless scene row. Renders the scene [SceneDisplayModel.name], its target room label, and an
 * active indicator that is composed ONLY when [SceneDisplayModel.isActive] is true. Tapping the row
 * hoists the activation request out via [onActivate]; the caller owns exclusive-activation state.
 *
 * [roomLabel] is supplied by the caller (resolved from a `roomNames` map, falling back to the raw
 * room id) so this row never reads any data source directly (D-008).
 */
@Composable
fun SceneRow(
    scene: SceneDisplayModel,
    roomLabel: String,
    onActivate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onActivate,
        modifier = modifier
            .fillMaxWidth()
            .testTag(sceneRowTag(scene.id)),
        shape = RoundedCornerShape(16.dp),
        color = if (scene.isActive) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surface
        },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = scene.name,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = roomLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (scene.isActive) {
                Text(
                    text = "Active",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.testTag(sceneActiveIndicatorTag(scene.id)),
                )
            }
        }
    }
}
