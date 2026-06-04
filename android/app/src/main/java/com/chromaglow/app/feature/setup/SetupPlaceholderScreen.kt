package com.chromaglow.app.feature.setup

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.hue.discovery.AndroidNsdBridgeDiscoveryService
import com.chromaglow.app.core.hue.discovery.BridgeDiscoverySnapshot
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.ui.theme.SetupGradientEnd
import com.chromaglow.app.ui.theme.SetupGradientMid
import com.chromaglow.app.ui.theme.SetupGradientStart

@Composable
fun SetupPlaceholderScreen(
    onEnterDemoMode: () -> Unit,
    modifier: Modifier = Modifier,
    onDiscoveredBridgeSelected: (BridgeEndpoint) -> Unit = {},
) {
    val applicationContext = LocalContext.current.applicationContext
    val discoveryService = remember(applicationContext) {
        AndroidNsdBridgeDiscoveryService(applicationContext)
    }
    var snapshot by remember {
        mutableStateOf(BridgeDiscoverySnapshot(isScanning = false, choices = emptyList()))
    }
    var selectedEndpoint by remember { mutableStateOf<BridgeEndpoint?>(null) }

    DisposableEffect(discoveryService) {
        onDispose { discoveryService.stop() }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        SetupGradientStart,
                        SetupGradientMid,
                        SetupGradientEnd,
                    ),
                ),
            ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = "ChromaGlow",
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.onBackground,
            )
            Text(
                text = "Connect to your Hue bridge or explore demo mode.",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Button(
                onClick = {
                    selectedEndpoint = null
                    discoveryService.start { snapshot = it }
                },
            ) {
                Text(text = "Scan for Bridge")
            }

            val selected = selectedEndpoint
            if (selected != null) {
                SelectedBridgeCard(bridge = selected)
            } else {
                if (snapshot.isScanning) {
                    Text(
                        text = "Searching…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (snapshot.choices.isNotEmpty()) {
                    Text(
                        text = "Select your bridge",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onBackground,
                    )
                    snapshot.choices.forEach { bridge ->
                        BridgeChoiceRow(
                            bridge = bridge,
                            onClick = {
                                discoveryService.stop()
                                selectedEndpoint = bridge
                                onDiscoveredBridgeSelected(bridge)
                            },
                        )
                    }
                }

                snapshot.statusMessage?.let { message ->
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (snapshot.isScanning || snapshot.choices.isNotEmpty() || selected != null) {
                OutlinedButton(
                    onClick = {
                        selectedEndpoint = null
                        discoveryService.stop()
                        discoveryService.start { snapshot = it }
                    },
                ) {
                    Text(text = "Scan Again")
                }
            }

            Button(onClick = onEnterDemoMode) {
                Text(text = "Enter Demo Mode")
            }
        }
    }
}

@Composable
private fun BridgeChoiceRow(
    bridge: BridgeEndpoint,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = bridge.name,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = bridge.displayAddress,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SelectedBridgeCard(
    bridge: BridgeEndpoint,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "Selected bridge",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
            )
            Text(
                text = bridge.name,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = bridge.displayAddress,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "Pairing will be added in a later step.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
