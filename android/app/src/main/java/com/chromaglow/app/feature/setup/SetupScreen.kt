package com.chromaglow.app.feature.setup

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.ui.theme.SetupGradientEnd
import com.chromaglow.app.ui.theme.SetupGradientMid
import com.chromaglow.app.ui.theme.SetupGradientStart

internal const val PAIRING_PROGRESS_TAG = "setup_pairing_progress"

internal const val LABEL_SCAN = "Scan for Bridge"
internal const val LABEL_MANUAL = "Enter IP Manually"
internal const val LABEL_USE_BRIDGE = "Use This Bridge"
internal const val LABEL_SCAN_AGAIN = "Scan Again"
internal const val LABEL_DEMO = "Enter Demo Mode"
internal const val LABEL_PAIR = "Pair"
internal const val LABEL_PAIRING = "Pairing…"
internal const val LABEL_FORGET = "Forget Bridge"
internal const val LABEL_TRY_AGAIN = "Try Again"
internal const val LABEL_RESET_SAVED = "Reset Saved Bridge Data"
internal const val RESET_IS_LOCAL_NOTE = "This clears saved bridge data on this device only."
internal const val TITLE_CONNECTED = "Bridge connected"
internal const val INSTRUCTION_PRESS_BUTTON = "Press the link button on your Hue bridge, then tap Pair."
internal const val FORGET_IS_LOCAL_NOTE = "This removes the bridge from this device only."

/**
 * Binds a [SetupViewModel] to the stateless [SetupScreen]. Used by both the production
 * [SetupPlaceholderScreen] and the Compose tests (with a fake-backed view model).
 */
@Composable
fun SetupRoute(
    viewModel: SetupViewModel,
    onEnterDemoMode: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SetupScreen(
        state = viewModel.uiState,
        onScanForBridge = viewModel::scanForBridge,
        onEnterManual = viewModel::enterManualEntry,
        onManualTextChange = viewModel::updateManualText,
        onSubmitManual = viewModel::submitManualEntry,
        onSelectDiscovered = viewModel::selectDiscoveredBridge,
        onScanAgain = viewModel::scanAgain,
        onPair = viewModel::pair,
        onTryAgain = viewModel::tryAgain,
        onForget = viewModel::forget,
        onResetSavedBridges = viewModel::resetSavedBridges,
        // L-55: leaving Setup for demo must release discovery + the multicast lock immediately.
        onEnterDemoMode = {
            viewModel.stopDiscovery()
            onEnterDemoMode()
        },
        modifier = modifier,
    )
}

/**
 * Stateless Setup content. Preserves scan / manual / Scan Again / demo, and renders the live
 * pairing card (Selected, Pairing, Paired, Recovery). No token is ever shown — only non-secret
 * names/addresses and static, user-safe copy.
 */
@Composable
fun SetupScreen(
    state: SetupUiState,
    onScanForBridge: () -> Unit,
    onEnterManual: () -> Unit,
    onManualTextChange: (String) -> Unit,
    onSubmitManual: () -> Unit,
    onSelectDiscovered: (BridgeEndpoint) -> Unit,
    onScanAgain: () -> Unit,
    onPair: () -> Unit,
    onTryAgain: () -> Unit,
    onForget: () -> Unit,
    onEnterDemoMode: () -> Unit,
    modifier: Modifier = Modifier,
    onResetSavedBridges: () -> Unit = {},
) {
    val pairing = state.pairing
    // The scan/manual entry controls are shown unless a bridge is actively selected, pairing, or
    // paired. Recovery keeps them so the user can re-scan, re-enter, or forget.
    val showEntryControls = pairing is BridgePairingUiState.None || pairing is BridgePairingUiState.Recovery

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(SetupGradientStart, SetupGradientMid, SetupGradientEnd),
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

            if (showEntryControls) {
                EntryControls(
                    state = state,
                    onScanForBridge = onScanForBridge,
                    onEnterManual = onEnterManual,
                    onManualTextChange = onManualTextChange,
                    onSubmitManual = onSubmitManual,
                    onSelectDiscovered = onSelectDiscovered,
                    onScanAgain = onScanAgain,
                )
            }

            when (pairing) {
                BridgePairingUiState.None -> Unit
                is BridgePairingUiState.Selected ->
                    SelectedBridgeCard(pairing, onPair = onPair, onScanAgain = onScanAgain)
                is BridgePairingUiState.Pairing -> PairingBridgeCard(pairing)
                is BridgePairingUiState.Paired -> PairedBridgeCard(pairing, onForget = onForget)
                is BridgePairingUiState.Recovery ->
                    RecoveryCard(
                        pairing,
                        onTryAgain = onTryAgain,
                        onForget = onForget,
                        onResetSavedBridges = onResetSavedBridges,
                    )
            }

            Button(onClick = onEnterDemoMode) {
                Text(text = LABEL_DEMO)
            }
        }
    }
}

@Composable
private fun EntryControls(
    state: SetupUiState,
    onScanForBridge: () -> Unit,
    onEnterManual: () -> Unit,
    onManualTextChange: (String) -> Unit,
    onSubmitManual: () -> Unit,
    onSelectDiscovered: (BridgeEndpoint) -> Unit,
    onScanAgain: () -> Unit,
) {
    Button(onClick = onScanForBridge) {
        Text(text = LABEL_SCAN)
    }

    OutlinedButton(onClick = onEnterManual) {
        Text(text = LABEL_MANUAL)
    }

    if (state.manualVisible) {
        OutlinedTextField(
            value = state.manualText,
            onValueChange = onManualTextChange,
            placeholder = { Text(text = "192.168.1.100") },
            singleLine = true,
            isError = state.manualError != null,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(MANUAL_ENTRY_FIELD_TAG),
        )
        state.manualError?.let { error ->
            Text(
                text = error,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
        Button(onClick = onSubmitManual) {
            Text(text = LABEL_USE_BRIDGE)
        }
    }

    if (state.isScanning) {
        Text(
            text = "Searching…",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (state.choices.isNotEmpty()) {
        Text(
            text = "Select your bridge",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        state.choices.forEach { bridge ->
            BridgeChoiceRow(bridge = bridge, onClick = { onSelectDiscovered(bridge) })
        }
    }

    state.statusMessage?.let { message ->
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (state.isScanning || state.choices.isNotEmpty()) {
        OutlinedButton(onClick = onScanAgain) {
            Text(text = LABEL_SCAN_AGAIN)
        }
    }
}

@Composable
private fun BridgeChoiceRow(bridge: BridgeEndpoint, onClick: () -> Unit) {
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
    state: BridgePairingUiState.Selected,
    onPair: () -> Unit,
    onScanAgain: () -> Unit,
) {
    BridgeCardSurface {
        BridgeIdentity(name = state.bridge.name, address = state.bridge.displayAddress)
        Text(
            text = state.retryMessage ?: INSTRUCTION_PRESS_BUTTON,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onPair) {
            Text(text = LABEL_PAIR)
        }
        OutlinedButton(onClick = onScanAgain) {
            Text(text = LABEL_SCAN_AGAIN)
        }
    }
}

@Composable
private fun PairingBridgeCard(state: BridgePairingUiState.Pairing) {
    BridgeCardSurface {
        BridgeIdentity(name = state.bridge.name, address = state.bridge.displayAddress)
        CircularProgressIndicator(modifier = Modifier.size(24.dp).testTag(PAIRING_PROGRESS_TAG))
        Text(
            text = LABEL_PAIRING,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun PairedBridgeCard(state: BridgePairingUiState.Paired, onForget: () -> Unit) {
    val record: PairedBridgeRecord = state.bridge
    BridgeCardSurface {
        Text(
            text = TITLE_CONNECTED,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        BridgeIdentity(name = record.name, address = "${record.host}:${record.port}")
        OutlinedButton(onClick = onForget) {
            Text(text = LABEL_FORGET)
        }
        Text(
            text = FORGET_IS_LOCAL_NOTE,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RecoveryCard(
    state: BridgePairingUiState.Recovery,
    onTryAgain: () -> Unit,
    onForget: () -> Unit,
    onResetSavedBridges: () -> Unit,
) {
    BridgeCardSurface {
        Text(
            text = state.message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
        )
        if (state.retryBridge != null) {
            Button(onClick = onTryAgain) {
                Text(text = LABEL_TRY_AGAIN)
            }
        }
        if (state.forgettableBridgeId != null) {
            OutlinedButton(onClick = onForget) {
                Text(text = LABEL_FORGET)
            }
        }
        if (state.canResetSavedBridges) {
            OutlinedButton(onClick = onResetSavedBridges) {
                Text(text = LABEL_RESET_SAVED)
            }
            Text(
                text = RESET_IS_LOCAL_NOTE,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun BridgeCardSurface(content: @Composable (() -> Unit)) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            content()
        }
    }
}

@Composable
private fun BridgeIdentity(name: String, address: String) {
    Text(
        text = name,
        style = MaterialTheme.typography.bodyLarge,
        color = MaterialTheme.colorScheme.onSurface,
    )
    Text(
        text = address,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}
