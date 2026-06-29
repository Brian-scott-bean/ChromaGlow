package com.chromaglow.app.feature.setup

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint

internal const val MANUAL_ENTRY_FIELD_TAG = "setup_manual_entry_field"

/**
 * App entry point for Setup. Kept source-compatible for `ChromaGlowApp` (only [onEnterDemoMode] is
 * required); it now builds a real, ViewModel-backed live-pairing route instead of an inert card.
 *
 * The view model wires the production transport, Keystore credential store, Preferences-DataStore
 * registry, and mDNS discovery via [SetupViewModel.factory]; the heavy collaborators are created
 * once and survive configuration changes. All pairing state lives in the view model — this entry
 * only injects it and forwards demo navigation.
 */
@Composable
fun SetupPlaceholderScreen(
    onEnterDemoMode: () -> Unit,
    modifier: Modifier = Modifier,
    onDiscoveredBridgeSelected: (BridgeEndpoint) -> Unit = {},
) {
    val context = LocalContext.current.applicationContext
    val viewModel: SetupViewModel = viewModel(
        factory = SetupViewModel.factory(context, onDiscoveredBridgeSelected),
    )
    SetupRoute(viewModel = viewModel, onEnterDemoMode = onEnterDemoMode, modifier = modifier)
}
