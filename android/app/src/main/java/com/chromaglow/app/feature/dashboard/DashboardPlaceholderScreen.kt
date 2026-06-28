package com.chromaglow.app.feature.dashboard

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
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.data.demo.DemoModeSession

@Composable
fun DashboardPlaceholderScreen(
    demoSession: DemoModeSession?,
    onBackToSetup: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val session = requireNotNull(demoSession) { "Demo session required" }
    require(session.isDemoMode)

    // Hold the rooms in in-memory Compose state so per-room toggle/brightness edits
    // re-render the rows. No persistence; resets when a new session is supplied.
    val rooms = remember(session) {
        mutableStateListOf<RoomDisplayModel>().apply { addAll(session.rooms) }
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
            text = "ChromaGlow",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = "Demo Dashboard",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(rooms, key = { it.id }) { room ->
                DemoRoomRow(
                    room = room,
                    onToggle = { isOn ->
                        val index = rooms.indexOfFirst { it.id == room.id }
                        if (index >= 0) {
                            rooms[index] = rooms[index].copy(isOn = isOn)
                        }
                    },
                    onBrightnessChange = { brightness ->
                        val index = rooms.indexOfFirst { it.id == room.id }
                        if (index >= 0) {
                            rooms[index] = rooms[index].copy(brightness = brightness.coerceIn(1, 100))
                        }
                    },
                )
            }
        }
        OutlinedButton(onClick = onBackToSetup) {
            Text(text = "Back to Setup")
        }
    }
}
