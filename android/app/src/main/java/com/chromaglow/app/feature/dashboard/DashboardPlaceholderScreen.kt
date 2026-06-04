package com.chromaglow.app.feature.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.chromaglow.app.data.demo.DemoModeSession

@Composable
fun DashboardPlaceholderScreen(
    demoSession: DemoModeSession?,
    onBackToSetup: () -> Unit,
    modifier: Modifier = Modifier,
) {
    require(demoSession?.isDemoMode == true)

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "ChromaGlow",
            style = MaterialTheme.typography.headlineLarge,
        )
        Text(
            text = "Demo Dashboard",
            style = MaterialTheme.typography.titleLarge,
        )
        Text(
            text = "Demo mode placeholder",
            style = MaterialTheme.typography.bodyLarge,
        )
        Button(onClick = onBackToSetup) {
            Text(text = "Back to Setup")
        }
    }
}
