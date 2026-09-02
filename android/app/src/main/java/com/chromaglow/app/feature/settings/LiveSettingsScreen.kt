package com.chromaglow.app.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.ui.components.ConnectionStrip

const val LIVE_SETTINGS_ROOT_TAG: String = "live_settings_root"
const val LIVE_SETTINGS_BACK_TAG: String = "live_settings_back"
const val LIVE_SETTINGS_MODE_TAG: String = "live_settings_mode"
const val LIVE_SETTINGS_VERSION_TAG: String = "live_settings_version"
const val LIVE_SETTINGS_FORGET_DIALOG_TAG: String = "live_settings_forget_dialog"
const val LIVE_SETTINGS_FORGET_CONFIRM_TAG: String = "live_settings_forget_confirm"
const val LIVE_SETTINGS_FORGET_CANCEL_TAG: String = "live_settings_forget_cancel"
const val FORGET_LOCAL_ONLY_NOTE: String = "This removes the bridge from this device only."

fun liveSettingsBridgeTag(bridgeId: BridgeId): String = "live_settings_bridge_${bridgeId.value}"
fun liveSettingsForgetTag(bridgeId: BridgeId): String = "live_settings_forget_${bridgeId.value}"

@Composable
fun LiveSettingsRoute(
    viewModel: LiveSettingsViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsState()
    LiveSettingsScreen(
        state = state,
        onBack = onBack,
        onRequestForget = viewModel::requestForget,
        onConfirmForget = viewModel::confirmForget,
        onCancelForget = viewModel::cancelForget,
        modifier = modifier,
    )
}

/**
 * Live Settings: mode, list-ready paired bridges (label, canonical id, connection status, a
 * local-only Forget per record behind a confirmation that states exactly what it does), About.
 * No Pair-another and no multi-bridge management in this slice.
 */
@Composable
fun LiveSettingsScreen(
    state: LiveSettingsUiState,
    onBack: () -> Unit,
    onRequestForget: (BridgeId) -> Unit,
    onConfirmForget: () -> Unit,
    onCancelForget: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp)
            .testTag(LIVE_SETTINGS_ROOT_TAG),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack, modifier = Modifier.testTag(LIVE_SETTINGS_BACK_TAG)) { Text("Back") }
            Text(
                text = "Settings",
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
        }

        SettingsCard {
            KeyValueRow(label = "Mode", value = state.modeLabel, valueTag = LIVE_SETTINGS_MODE_TAG)
        }

        Text(
            text = "Bridges",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.semantics { heading() },
        )
        if (state.bridges.isEmpty()) {
            SettingsCard { Text("No bridge is paired on this device.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        state.bridges.forEach { bridge ->
            SettingsCard(modifier = Modifier.testTag(liveSettingsBridgeTag(bridge.bridgeId))) {
                Text(bridge.label, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                KeyValueRow(label = "Bridge ID", value = bridge.bridgeId.value)
                ConnectionStrip(rows = listOf(bridge.row))
                OutlinedButton(
                    onClick = { onRequestForget(bridge.bridgeId) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(liveSettingsForgetTag(bridge.bridgeId)),
                ) { Text("Forget Bridge") }
                Text(FORGET_LOCAL_ONLY_NOTE, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        Text(
            text = "About",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.semantics { heading() },
        )
        SettingsCard {
            KeyValueRow(label = "App version", value = state.appVersion, valueTag = LIVE_SETTINGS_VERSION_TAG)
            Text(
                text = "ChromaGlow controls Philips Hue lights on your local network. Hue is a trademark of Signify; this app is not affiliated with or endorsed by Signify.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }

    state.confirmingForget?.let { id ->
        AlertDialog(
            onDismissRequest = onCancelForget,
            modifier = Modifier.testTag(LIVE_SETTINGS_FORGET_DIALOG_TAG),
            title = { Text("Forget this bridge?") },
            text = {
                Text("$FORGET_LOCAL_ONLY_NOTE Your lights and scenes stay on the bridge, and this app's key stays there until you remove it in the Hue app. You can pair again at any time.")
            },
            confirmButton = {
                TextButton(onClick = onConfirmForget, modifier = Modifier.testTag(LIVE_SETTINGS_FORGET_CONFIRM_TAG)) { Text("Forget Bridge") }
            },
            dismissButton = {
                TextButton(onClick = onCancelForget, modifier = Modifier.testTag(LIVE_SETTINGS_FORGET_CANCEL_TAG)) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SettingsCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

@Composable
private fun KeyValueRow(label: String, value: String, valueTag: String? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
        Text(
            value,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = if (valueTag != null) Modifier.testTag(valueTag) else Modifier,
        )
    }
}
