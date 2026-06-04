package com.chromaglow.app.feature.dashboard

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.RoomDisplayModel

@Composable
fun DemoRoomRow(
    room: RoomDisplayModel,
    modifier: Modifier = Modifier,
) {
    val statusLine = buildString {
        append(if (room.isOn) "On" else "Off")
        append(" · ")
        append(room.brightness)
        append("% · ")
        append(room.lightCount)
        append(" lights")
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (room.isOn) 1f else 0.72f),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = room.name,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = statusLine,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
