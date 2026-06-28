package com.chromaglow.app.feature.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.SceneDisplayModel

/**
 * Scenes list screen. Renders one [SceneRow] per scene in [scenes], showing the scene name, its
 * target room (resolved as `roomNames[scene.roomId] ?: scene.roomId`), and an active indicator.
 *
 * Active state is held internally via a Compose-state copy of [scenes] (see [remember]). Activation
 * is EXCLUSIVE: tapping a scene sets that scene's [SceneDisplayModel.isActive] to true (via
 * [SceneDisplayModel.copy]) and clears every other scene. The selected scene's
 * [SceneDisplayModel.bridgeId] and [SceneDisplayModel.id] are forwarded to [onActivateScene] so the
 * caller can route activation by bridge. The composable receives its model collection through
 * parameters and reads no data source directly (D-008).
 */
@Composable
fun ScenesScreen(
    scenes: List<SceneDisplayModel>,
    roomNames: Map<String, String> = emptyMap(),
    onActivateScene: (String, String) -> Unit = { _, _ -> },
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    // Hold the scenes in in-memory Compose state so exclusive activation re-renders the rows.
    // No persistence; resets when a new [scenes] list is supplied.
    val sceneState = remember(scenes) {
        mutableStateListOf<SceneDisplayModel>().apply { addAll(scenes) }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Scenes",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(sceneState, key = { it.id }) { scene ->
                SceneRow(
                    scene = scene,
                    roomLabel = roomNames[scene.roomId] ?: scene.roomId,
                    onActivate = {
                        // Exclusive activation: the tapped scene becomes active, all others clear.
                        for (index in sceneState.indices) {
                            val current = sceneState[index]
                            sceneState[index] = current.copy(isActive = current.id == scene.id)
                        }
                        onActivateScene(scene.bridgeId, scene.id)
                    },
                )
            }
        }
        OutlinedButton(onClick = onBack) {
            Text(text = "Back")
        }
    }
}
